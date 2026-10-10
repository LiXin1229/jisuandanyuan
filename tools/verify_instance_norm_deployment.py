"""Gate residual IN deployment: same-frame pixels, native simulations, routed resources."""
from pathlib import Path
from datetime import datetime,timezone
import argparse,hashlib,json,re,subprocess,sys,zlib
import numpy as np
from PIL import Image
from cyclegan_host import ArrayCore,GeneratorScheduler
from live_norm_reference import BN_BASES
ROOT=Path(__file__).resolve().parents[1]
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def pair_check(pair,live_points=18):
    report=json.loads((pair/'capture_report.json').read_text())
    assert report['pass_matched_capture']
    rgbx=np.frombuffer((pair/'camera_original.rgbx').read_bytes(),dtype=np.uint8).reshape(240,320,4)
    assert not np.any(rgbx[:,:,3]);rgb=rgbx[:,:,:3]
    Image.fromarray(rgb).save(pair/'camera_original.png')
    stream=((rgb.astype(np.int64)-124)>>3).astype(np.int8).reshape(24,10,32,10,3).transpose(0,2,1,4,3).tobytes()
    assert zlib.crc32(stream)==report['frozen']['input_checksum'],'Camera pair is not the processed input'
    model=pair/'reference'
    with (pair/'reference.log').open('w') as log:
        subprocess.run([sys.executable,'-B',str(ROOT/'tools/prepare_instance_norm_model.py'),
                        '--image',str(pair/'camera_original.png'),'--output',str(model),'--live-points',str(live_points)],
                       stdout=log,stderr=subprocess.STDOUT,check=True)
    manifest=json.loads((model/'params_manifest.json').read_text())
    assert manifest['live_normalization_ids']==(list(range(5,23)) if live_points==18 else list(range(live_points)))
    assert sha(model/'generator_params_q88.mem')==sha(ROOT/'build/cyclegan_model/generator_params_q88.mem')
    weights=[int(v,16) for v in (model/'generator_params_q88.mem').read_text().split()]
    weights=[v-65536 if v&32768 else v for v in weights]
    records=json.loads((model/'vectors/live_normalization.json').read_text())['coefficients']
    assert len(records)==live_points
    for point in records:
        base=BN_BASES[point['id']]
        for ch,(a,b) in enumerate(zip(point['a'],point['b'])):weights[base+2*ch:base+2*ch+2]=[a,b]
    lut=[int(v,16) for v in (model/'tanh_u8.mem').read_text().split()]
    scheduler=GeneratorScheduler(ArrayCore(weights,lut),manifest)
    result=scheduler.run(rgb,verify=model/'vectors')
    assert len(scheduler.layer_results)==16
    padded=np.frombuffer((pair/'fpga_styled.tiles').read_bytes(),dtype=np.uint8).reshape(2304,128)
    assert not np.any(padded[:,50:64]) and not np.any(padded[:,114:128])
    packed=np.concatenate((padded[:,:50],padded[:,64:114]),axis=1).tobytes()
    expected=(model/'vectors/output_u8_tiles.bin').read_bytes()
    assert len(packed)==len(expected)==230400
    mismatches=sum(a!=b for a,b in zip(packed,expected))
    assert mismatches==0,('IN FPGA/reference mismatch',mismatches)
    actual=np.frombuffer(packed,dtype=np.uint8).reshape(3,24,32,2,2,5,5).transpose(0,1,3,5,2,4,6).reshape(3,240,320)
    assert np.array_equal(actual,result)
    Image.fromarray(actual.transpose(1,2,0)).save(pair/'fpga_styled.png')
    comparison=dict(values=230400,mismatches=mismatches,max_absolute_error=0,instruction_layers_checked=16,
                    live_normalization_ids=manifest['live_normalization_ids'],live_channels=sum(len(v['a']) for v in records),
                    input_rgbx_sha256=sha(pair/'camera_original.rgbx'),fpga_padded_sha256=sha(pair/'fpga_styled.tiles'),
                    input_checksum=zlib.crc32(stream),output_rgb_sha256=hashlib.sha256(actual.tobytes()).hexdigest())
    (pair/'comparison.json').write_text(json.dumps(comparison,indent=2)+'\n')
    print(f'INSTANCE_VIDEO_PAIR_PASS 230400 bytes; {live_points} IN points; 16 instruction-model tensors',flush=True)

def record(out):
    project=Path((out/'staging_path.txt').read_text(encoding='utf-8-sig').strip())
    manifest=json.loads((project/'source_manifest.json').read_text())
    assert all(sha(ROOT/'rtl'/n)==v for n,v in manifest['rtl_sha256'].items())
    assert all(sha(ROOT/'board/video'/n)==v for n,v in manifest['board_sha256'].items())
    bit_sha=sha(project/'outflow/encoder_board.bit')
    programming=(out/'program.log').read_text()
    assert '0x10660A79' in programming and 'finished with JTAG programming' in programming
    for flow in ('map','pnr','pgm'):
        assert re.search(flow+r'\s*:\s*PASS',(project/(flow+'.console.log')).read_text())
    resources=json.loads((out/'resources.json').read_text())
    assert resources['EFX_DSP48']<=104 and resources['EFX_DSP24']<=4
    assert resources['EFX_RAM10']+resources['EFX_DPRAM10']<=256
    timing=(project/'outflow/encoder_board.timing.rpt').read_text()
    rows=re.findall(r'^\s*(\w+)\s+(\w+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+\(',timing,re.M)
    assert rows and all(float(r[3])>=0 for r in rows)
    native=ROOT/'build/instance_residual_verified';simulations={}
    for name,marker in [('coeff_edge.log','PASS instance coefficient: 260 cases'),
                        ('seeded.log','PASS instance residual: coefficients=576 residual_values=345600'),
                        ('output_delay2.log','PASS stage4: full_prefix=1 output_only=0 values=1075200 residual_values=345600 commands=170880'),
                        ('output_inverted_delay45.log','PASS stage4: full_prefix=1 output_only=0 values=1075200 residual_values=345600 commands=170880')]:
        log=(native/name).read_text();assert marker in log and '** Fatal:' not in log
        simulations[name]=dict(sha256=sha(native/name),pass_line=next(l.strip() for l in log.splitlines() if marker in l))
    for stem in ('output','output_inverted'):
        stage=Path((native/(stem+'_path.txt')).read_text(encoding='utf-8-sig').strip())
        hashes={n:sha(stage/n) for n in manifest['rtl_sha256'] if (stage/n).exists()}
        assert len(hashes)>=20 and all(v==manifest['rtl_sha256'][n] for n,v in hashes.items()),'Stale simulation RTL'
        assert sha(stage/'norm_sqrt80.v')==sha(ROOT/'rtl/ip/norm_sqrt80/norm_sqrt80.v')
        assert sha(stage/'norm_div64_40.sv')==sha(ROOT/'sim/vendor/norm_div64_40.sv')
        assert sha(stage/'tb_cyclegan_output.sv')==sha(ROOT/'sim/tb_cyclegan_output.sv')
    for name,marker in [('unit.log','PASS:'),('bus.log','PASS bus:'),('executor_cycles.log','PASS cycle model:')]:
        text=(ROOT/'build/sim'/name).read_text();assert marker in text and '** Fatal:' not in text
        simulations[name]=dict(sha256=sha(ROOT/'build/sim'/name),pass_line=next(l.strip() for l in text.splitlines() if marker in l))
    streams=[json.loads((out/name).read_text()) for name in ('stream_style.json','stream_original.json','stream_restore.json')]
    assert (streams[-1]['final']['control_packed']>>10)&7==0,'Physical key control was not restored'
    for stream in streams:
        assert stream['hardware_stream_pass'] and stream['bitstream_sha256']==bit_sha
        assert stream['processing_sample']['residual_cycles']==442926
        assert stream['processing_sample']['prefix_mac_cycles']==4974864
        assert stream['processing_sample']['command_wait_cycles']==0
    pair=out/'live_pair';capture=json.loads((pair/'capture_report.json').read_text())
    comparison=json.loads((pair/'comparison.json').read_text())
    assert capture['pass_matched_capture'] and capture['bitstream_sha256']==bit_sha
    assert comparison['mismatches']==0 and comparison['live_channels']==576
    baseline=json.loads((ROOT/'docs/analysis/cyclegan_video_schedule_optimization.json').read_text())
    previous=baseline['resources']
    delta={n:v-previous.get(n,0) for n,v in resources.items()}
    result=dict(timestamp_utc=datetime.now(timezone.utc).isoformat(),stage='residual same-frame IN: 18/26 points',
                sources=manifest,project=str(project),bitstream_sha256=bit_sha,resources=resources,resource_delta=delta,
                timing_rows=rows,simulations=simulations,live_streams=streams,matched_capture=capture,numerical_comparison=comparison,
                programming_log_sha256=sha(out/'program.log'),checkpoint_sha256=json.loads((pair/'reference/params_manifest.json').read_text())['checkpoint_sha256'],
                tool_sha256={n:sha(ROOT/n) for n in ('tools/prepare_instance_norm_model.py','tools/prepare_instance_norm_deployment.py',
                 'tools/live_norm_reference.py','tools/verify_instance_norm_deployment.py','scripts/run_instance_norm_modelsim.ps1',
                 'scripts/run_instance_norm_coeff.ps1','scripts/run_video_board.ps1','scripts/verify_instance_norm_board.ps1')},
                report_sha256={n:sha(project/'outflow'/n) for n in ('encoder_board.map.rpt','encoder_board.timing.rpt')},
                residual_cycles_before=442395,residual_cycles_after=442926,residual_extra_cycles=531,
                residual_extra_us=531/(2400/14),coefficient_cycles=248,feature_ddr_transactions_added=0,
                pending_live_normalization_ids=[0,1,2,3,4,23,24,25])
    target=ROOT/'docs/analysis/cyclegan_residual_instance_norm.json'
    target.write_text(json.dumps(result,indent=2)+'\n')
    (out/'verification.json').write_text(json.dumps(result,indent=2)+'\n')
    print('INSTANCE_NORM_DEPLOYMENT_PASS '+str(target),flush=True)

if __name__=='__main__':
    cli=argparse.ArgumentParser(description=__doc__);cli.add_argument('--pair',type=Path)
    cli.add_argument('--live-points',type=int,choices=(18,23,26),default=18)
    cli.add_argument('--record',action='store_true');cli.add_argument('--out',type=Path,default=ROOT/'build/video_instance_residual_verified')
    args=cli.parse_args()
    if args.pair:pair_check(args.pair.resolve(),args.live_points)
    if args.record:record(args.out.resolve())
