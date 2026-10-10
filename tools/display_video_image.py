"""Upload one RGBx frame, run the current FPGA network, leave styled HDMI frozen.

The image/reference is prepared by prepare_instance_norm_model.py. No host
network output is uploaded: only the original pixels cross the JTAG input.
"""
from pathlib import Path
from datetime import datetime, timezone
import argparse, hashlib, json, time, zlib
from debug_video import VideoBoard


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image',type=Path,required=True)
    parser.add_argument('--reference',type=Path,required=True)
    parser.add_argument('--project',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--url',default='ftdi://0x0403:0x6014:3:7/1')
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    manifest=json.loads((args.reference/'params_manifest.json').read_text())
    assert manifest['reference_image_sha256']==sha(args.image),'Stale image reference'
    assert manifest['live_normalization_ids'] in (list(range(5,23)),list(range(23)),list(range(26)))
    raw=(args.reference/'vectors/frame_rgbx.bin').read_bytes()
    assert len(raw)==307200 and not any(raw[3::4])
    stream=bytes(((raw[((ty*10+row)*320+tx*10+pixel)*4+channel]-124)>>3)&255
                 for ty in range(24) for tx in range(32) for row in range(10)
                 for channel in range(3) for pixel in range(10))
    expected_crc=zlib.crc32(stream)
    report=dict(started_utc=datetime.now(timezone.utc).isoformat(),image=str(args.image.resolve()),
                image_sha256=sha(args.image),input_rgbx_sha256=hashlib.sha256(raw).hexdigest(),
                input_checksum=expected_crc,project=str(args.project.resolve()),
                bitstream_sha256=sha(args.project/'outflow/encoder_board.bit'),pass_image_display=False)
    board=VideoBoard(args.url,profile_path=args.project/'debug_profile.json')
    try:
        assert board.signature==0xe317 and board.has_payload,'Requires HOST_IMAGE bitstream'
        board.command(3,7);entry=board.snapshot();report['entry']=entry
        assert entry['status']&0xc000==0xc000 and not entry['status']&0x3e01,entry
        assert not entry['input_slots'],'Another input frame is owned'
        state=board.command(1)
        assert not state['status']&0x3c01,state
        begin=time.monotonic()
        for chunk in range(4800):
            state=board.command(2,payload=int.from_bytes(raw[chunk*64:(chunk+1)*64],'little'))
            assert not state['status']&0x3c01,state
            if chunk%600==599:
                print(f'IMAGE_UPLOAD {chunk+1}/4800 chunks seconds={time.monotonic()-begin:.1f}',flush=True)
        deadline=time.monotonic()+3
        while board.metric(22)!=entry['captured_frames']+1:
            if time.monotonic()>deadline:raise TimeoutError('Photo input DDR commit')
        report['upload_seconds']=time.monotonic()-begin
        board.command(3,3);deadline=time.monotonic()+5
        while True:
            state=board.read()
            assert not state['status']&0x3c01,state
            if state['processed_frames']==entry['processed_frames']+1 and not state['status']&512:break
            if time.monotonic()>deadline:raise TimeoutError('Photo network did not complete')
        board.command(3,7);time.sleep(.3)
        styled=board.snapshot();report['styled_display']=styled
        expected_sum=sum((args.reference/'vectors/output_u8_tiles.bin').read_bytes())*4&0xffffffff
        assert styled['active_style'] and styled['pixel_sum']==expected_sum,styled
        assert styled['input_checksum']==expected_crc and styled['completed']==9,styled
        assert styled['output_status']==7 and styled['command_wait_cycles']==0,styled
        assert not styled['underflows'] and not styled['original_checksum_errors'],styled
        assert not styled['fifo_overflows'] and not styled['crop_overruns'],styled
        assert not styled['status']&0x3e01,styled
        report['styled_expected_hdmi_sum']=expected_sum
        report['pass_image_display']=True
        print('IMAGE_FPGA_HDMI_PASS '+json.dumps(styled),flush=True)
    except Exception as exc:
        report['error']=str(exc);raise
    finally:
        board.close()
        report['finished_utc']=datetime.now(timezone.utc).isoformat()
        (args.output/'image_display.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':main()
