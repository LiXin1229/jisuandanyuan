"""Check BusCore packing/masks/status against a word-addressed bus model.

This checks the Python transport protocol; RTL bus timing is checked separately
by tb_mobilenet_bus and tb_cyclegan_bus.
"""
from pathlib import Path
import sys
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from cyclegan_host import ArrayCore, BusCore
from mn_codec import Instruction, Operation, pack_tile, unpack_tile


class WordBus:
    def __init__(self, core):
        self.core = core
        self.staging = [0] * 25
        self.command = [0] * 4
        self.address = 0
        self.mask = 0
        self.done = False

    def read_word(self, address):
        if address == 0:
            return 4 | (2 if self.done else 0)
        return self.staging[address - 32]

    def write_word(self, address, data):
        if address == 0:
            if data & 2:
                self.done = False
        elif address == 1:
            self.address = data
        elif address == 2:
            self.mask = sum(((1 << 10) - 1) << (10*q) for q in range(4) if data & (1 << q))
        elif address == 3:
            old = pack_tile([int(x) for x in self.core.cache.get(self.address, np.zeros((10, 10))).flat])
            new = sum(x << (32*i) for i, x in enumerate(self.staging))
            bits = sum(((1 << 20) - 1) << (20*i) for i in range(40) if self.mask & (1 << i))
            tile = np.array(unpack_tile((old & ~bits) | (new & bits))).reshape(10, 10)
            self.core.write_tile(self.address, tile)
        elif address == 4:
            word = pack_tile([int(x) for x in self.core.read_tile(self.address).flat])
            self.staging = [(word >> (32*i)) & 0xffffffff for i in range(25)]
        elif address == 7:
            encoded = sum(x << (32*i) for i, x in enumerate(self.command))
            class Encoded:
                def encode(self):
                    return encoded
            self.core.execute(Encoded())
            self.done = True
        elif 8 <= address <= 11:
            self.command[address-8] = data
        elif address == 12:
            self.mask = (self.mask & (255 << 32)) | data
        elif address == 13:
            self.mask = (self.mask & 0xffffffff) | (data << 32)
        elif 32 <= address <= 56:
            self.staging[address-32] = data
        else:
            raise AssertionError(f'Unexpected register {address}')


def main():
    words = [int(x, 16) for x in (ROOT/'build/cyclegan_model/generator_params_q88.mem').read_text().split()]
    words = [x-65536 if x >= 32768 else x for x in words]
    lut = [int(x, 16) for x in (ROOT/'rtl/mn_tanh_u8.mem').read_text().split()]
    model = ArrayCore(words, lut)
    driver = BusCore(WordBus(model))
    expected = ((np.arange(100).reshape(10, 10)*11) % 256) - 128
    for address in (0, 511, 512, 1023, 1024, 1350, 1486):
        driver.write_tile(address, expected)
        tile = expected.copy()
        for row in (9, 0, 5, 4, 1, 8, 2, 7, 3, 6):
            pixels = ((np.arange(10)*37 + row*19) % 256) - 128
            tile[row] = pixels
            driver.write_row(address, row, pixels)
            assert np.array_equal(driver.read_tile(address), tile), (address, row)
    # Four command words must retain the high parameter and cache address bits.
    driver.execute(Instruction(Operation.CONV, src=1350, dst=1351, parameter=20427,
                               kernel=5, tanh=True))
    raw = model.cache[1350]*words[20427]
    result = np.asarray(lut)[np.clip((raw+8) >> 4, -2048, 2047)+2048]
    result = np.where(result >= 128, result-256, result)
    assert np.array_equal(driver.read_tile(1351), result)
    print('PASS host protocol: 70 row commits/readbacks, 7 cache addresses, extended CONV/Tanh command')


if __name__ == '__main__':
    main()
