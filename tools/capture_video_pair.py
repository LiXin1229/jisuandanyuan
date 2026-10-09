"""Freeze and read a matched camera RGBx/network-tile pair over Efinity JTAG.

Reads the published output bank, not the camera input banks that may still be
receiving frames. Restores the entry VIO control in finally, unless requested
to keep the display paused. No FPGA programming is performed.
"""
from pathlib import Path
from datetime import datetime, timezone
import argparse
import hashlib
import json
import time

from debug_video import VideoBoard


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def read_region(board, base, length, label, output):
    data = bytearray()
    repeated = []
    start = time.monotonic()
    for offset in range(0, length, 64):
        response = board.command(6, (base+offset) >> 4)
        if response['status'] & 0x3c01:
            raise RuntimeError(f'DDR read fault: {response["status"]:08x}')
        block = response['data'].to_bytes(64, 'little')
        data.extend(block)
        if offset % 12800 == 0:
            again = board.command(6, (base+offset) >> 4)['data'].to_bytes(64, 'little')
            if block != again:
                repeated.append(offset)
        if offset % 30720 == 0:
            print(f'PAIR_READ {label} {offset}/{length}', flush=True)
    output.write_bytes(data)
    return dict(base=base, bytes=length, sha256=sha256(data),
                seconds=time.monotonic()-start, repeated_read_mismatch_offsets=repeated)


def stable_identity(snapshot):
    return (snapshot['frame_id'], snapshot['processed_frames'], snapshot['active_slot'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', default='ftdi://0x0403:0x6014:3:7/1')
    parser.add_argument('--profile', type=Path)
    parser.add_argument('--bitstream', type=Path,
                        help='Record the programmed bitstream hash alongside the matched pair.')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--frequency', type=float, default=3e6)
    parser.add_argument('--leave-paused', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    board = VideoBoard(args.url, args.frequency, args.profile)
    saved_control = None
    report = dict(started_utc=datetime.now(timezone.utc).isoformat(),
                  efinity_version='2026.1', usb_url=args.url,
                  bitstream_sha256=sha256(args.bitstream.read_bytes()) if args.bitstream else None,
                  pass_matched_capture=False, original_layout='240x320 RGBx uint8',
                  styled_layout='3 channels x 24x32 tiles; 50 valid + 14 zero + 50 valid + 14 zero')
    try:
        entry = board.snapshot()
        saved_control = (entry['control_packed'] >> 10) & 7
        report['entry'] = entry
        board.command(3, 5)  # Paused, force original display for checksum verification.
        deadline = time.monotonic() + 5
        while board.read()['status'] & 512:
            if time.monotonic() > deadline:
                raise TimeoutError('Current network calculation did not finish')
            time.sleep(.01)
        time.sleep(.25)  # Allow publication and display acknowledgement at VSYNC.
        frozen = board.snapshot()
        report['frozen'] = frozen
        print('PAIR_FROZEN ' + json.dumps(frozen), flush=True)
        if not frozen['processed_frames'] or frozen['completed'] != 9:
            raise RuntimeError('There is no complete network frame to capture')
        if frozen['active_style'] or frozen['status'] & 0x3e01:
            raise RuntimeError('Display did not reach a healthy paused original frame')
        slot = int(frozen['active_slot'])
        original_base = 0x900000 if slot else 0x800000
        styled_base = 0x700000 if slot else 0x600000
        report['original'] = read_region(board, original_base, 240*320*4,
                                         'original', args.output/'camera_original.rgbx')
        after_original = board.snapshot()
        report['after_original'] = after_original
        if stable_identity(after_original) != stable_identity(frozen):
            raise RuntimeError('Published frame changed while reading the original')
        original_data = (args.output/'camera_original.rgbx').read_bytes()
        # RGBx filler bytes must be zero in the current camera writer.
        report['original_padding_nonzero'] = sum(v != 0 for v in original_data[3::4])
        scale = frozen['display_scale']
        report['display_scale'] = scale
        expected_sum = sum(original_data)*scale*scale & 0xffffffff
        report['original_expected_hdmi_sum'] = expected_sum
        report['original_measured_hdmi_sum'] = after_original['pixel_sum']
        report['styled'] = read_region(board, styled_base, 3*24*32*128,
                                       'styled', args.output/'fpga_styled.tiles')
        after_styled = board.snapshot()
        report['after_styled'] = after_styled
        if stable_identity(after_styled) != stable_identity(frozen):
            raise RuntimeError('Published frame changed while reading the network output')
        board.command(3, 7)  # Verify the HDMI renderer checksum for the same styled frame.
        time.sleep(.25)
        styled_display = board.snapshot()
        report['styled_display'] = styled_display
        styled_data = (args.output/'fpga_styled.tiles').read_bytes()
        styled_sum = sum(sum(styled_data[i:i+50])+sum(styled_data[i+64:i+114]) for i in range(0, len(styled_data), 128))*scale*scale & 0xffffffff
        report['styled_padding_nonzero'] = sum(v != 0 for i in range(0,len(styled_data),64) for v in styled_data[i+50:i+64])
        report['styled_expected_hdmi_sum'] = styled_sum
        report['styled_measured_hdmi_sum'] = styled_display['pixel_sum']
        report['pass_matched_capture'] = (
            stable_identity(styled_display) == stable_identity(frozen)
            and styled_display['active_style']
            and not report['original']['repeated_read_mismatch_offsets']
            and not report['styled']['repeated_read_mismatch_offsets']
            and report['original_padding_nonzero'] == 0 and report['styled_padding_nonzero'] == 0
            and expected_sum == after_original['pixel_sum']
            and styled_sum == styled_display['pixel_sum']
            and not styled_display['status'] & 0x3e01
            and not styled_display['underflows']
            and not styled_display['original_checksum_errors'])
    except Exception as exc:
        report['error'] = str(exc)
        raise
    finally:
        try:
            if saved_control is not None:
                board.command(3, (saved_control | 4) if args.leave_paused else saved_control)
                report['restored_control'] = (saved_control | 4) if args.leave_paused else saved_control
        finally:
            board.close()
            report['finished_utc'] = datetime.now(timezone.utc).isoformat()
            (args.output/'capture_report.json').write_text(json.dumps(report, indent=2)+'\n')
    print(('MATCHED_PAIR_CAPTURE_PASS ' if report['pass_matched_capture'] else
           'MATCHED_PAIR_CAPTURE_NOT_VERIFIED ') + str(args.output), flush=True)
    if not report['pass_matched_capture']:
        raise SystemExit(2)


if __name__ == '__main__':
    main()
