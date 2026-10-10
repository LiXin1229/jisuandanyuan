"""Record routed resources, exact photo identity, FPGA output and HDMI gates."""
from pathlib import Path
from datetime import datetime, timezone
import argparse, hashlib, json, re
import numpy as np
from PIL import Image

ROOT=Path(__file__).resolve().parents[1]


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def record(out):
    project=Path((out/'staging_path.txt').read_text(encoding='utf-8-sig').strip())
    manifest=json.loads((project/'source_manifest.json').read_text())
    deployment=manifest['video_contract']
    assert deployment['input_mode']=='JTAG fixed RGBx image; sensor disabled'
    for name,digest in manifest['rtl_sha256'].items():
        assert sha(ROOT/'rtl'/name)==digest,('Stale source',name)
        staged=project/(Path(name).name if name.startswith('video/') else name)
        expected=deployment['staged_top_sha256'] if name=='video/cyclegan_camera_board.sv' else digest
        assert sha(staged)==expected,('Stale deployed source',name)
    assert all(sha(ROOT/'board/video'/n)==h for n,h in manifest['board_sha256'].items())
    profile=json.loads((project/'debug_profile.json').read_text())
    assert profile['debug_cores'][0]['uuid']=='e3177cfe3110414c8c948a9d7e1e3ac5'
    for flow in ('map','pnr','pgm'):
        assert re.search(flow+r'\s*:\s*PASS',(project/(flow+'.console.log')).read_text())
    timing=(project/'outflow/encoder_board.timing.rpt').read_text()
    rows=re.findall(r'^\s*(\w+)\s+(\w+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+\(',timing,re.M)
    assert rows and all(float(r[3])>=0 for r in rows)
    resources=json.loads((out/'resources.json').read_text())
    assert resources['EFX_RAM10']+resources['EFX_DPRAM10']<=256
    assert resources['EFX_DSP48']<=104 and resources['EFX_DSP24']<=4
    bit=sha(project/'outflow/encoder_board.bit')
    programming=(out/'program.log').read_text()
    assert '0x10660A79' in programming and 'finished with JTAG programming' in programming
    display=json.loads((out/'image_display.json').read_text())
    assert display['pass_image_display'] and display['bitstream_sha256']==bit
    pair=out/'photo_pair'
    capture=json.loads((pair/'capture_report.json').read_text())
    comparison=json.loads((pair/'comparison.json').read_text())
    assert capture['pass_matched_capture'] and capture['bitstream_sha256']==bit
    assert capture['restored_control']==7 and capture['styled_display']['active_style']
    assert comparison['values']==230400 and comparison['mismatches']==0
    source=Path(display['image'])
    assert sha(source)==display['image_sha256']
    rgb=np.asarray(Image.open(source).convert('RGB'))
    actual=np.frombuffer((pair/'camera_original.rgbx').read_bytes(),np.uint8).reshape(240,320,4)
    assert rgb.shape==(240,320,3) and np.array_equal(actual[:,:,:3],rgb) and not actual[:,:,3].any()
    assert sha(pair/'camera_original.rgbx')==display['input_rgbx_sha256']
    assert comparison['input_checksum']==display['input_checksum']
    simulations={}
    for name,marker in [('image_sim.log','PASS camera fixed image:'),('board_sim.log','PASS camera board protocol:')]:
        text=(out/name).read_text();assert marker in text and '** Fatal:' not in text
        simulations[name]=dict(sha256=sha(out/name),pass_line=next(l for l in text.splitlines() if marker in l))
    # Reuse the previous native full-network proof only for identical core RTL.
    points=deployment['normalization']['live_points']
    baseline=ROOT/'docs/analysis'/({18:'cyclegan_residual_instance_norm.json',23:'cyclegan_encoder_instance_norm.json',26:'cyclegan_full_instance_norm.json'}[points])
    previous=json.loads(baseline.read_text())
    unchanged_core={n:h for n,h in manifest['rtl_sha256'].items() if not n.startswith('video/')}
    previous_sources=previous.get('source_manifest',previous.get('sources'))
    assert all(previous_sources['rtl_sha256'].get(n)==h for n,h in unchanged_core.items())
    result=dict(timestamp_utc=datetime.now(timezone.utc).isoformat(),pass_photo_deployment=True,
                project=str(project),bitstream_sha256=bit,resources=resources,timing_rows=rows,
                image_display=display,matched_capture=capture,numerical_comparison=comparison,
                simulations=simulations,source_manifest=manifest,unchanged_compute_rtl_sha256=unchanged_core,
                parent_native_network_evidence_sha256=sha(baseline),
                programming_log_sha256=sha(out/'program.log'),
                report_sha256={n:sha(project/'outflow'/n) for n in ('encoder_board.map.rpt','encoder_board.timing.rpt')},
                normalization=deployment['normalization'],
                final_display='frozen network output; control=7; source selection=JTAG image')
    (out/'verification.json').write_text(json.dumps(result,indent=2)+'\n')
    (ROOT/'docs/analysis/cyclegan_video_image.json').write_text(json.dumps(result,indent=2)+'\n')
    print('VIDEO_IMAGE_DEPLOYMENT_PASS '+str(out),flush=True)


if __name__=='__main__':
    cli=argparse.ArgumentParser(description=__doc__)
    cli.add_argument('--out',type=Path,default=ROOT/'build/video_image_verified')
    record(cli.parse_args().out.resolve())
