"""Record measured 23/26 point IN evidence; fail on stale RTL or pixel differences."""
from pathlib import Path
import argparse,hashlib,json,re

ROOT=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text(encoding='utf-8-sig'))

def project_check(out,points):
    project=Path((out/'staging_path.txt').read_text(encoding='utf-8-sig').strip())
    manifest=read(project/'source_manifest.json')
    assert manifest['video_contract']['normalization']['live_points']==points
    assert all(sha(ROOT/'rtl'/n)==h for n,h in manifest['rtl_sha256'].items()),'Stale hardware RTL'
    assert sha(project/'cyclegan_camera_board.sv')==manifest['video_contract']['staged_top_sha256']
    for flow in ('map','pnr','pgm'):
        assert re.search(flow+r'\s*:\s*PASS',(project/(flow+'.console.log')).read_text())
    timing=re.findall(r'^\s*(\w+)\s+(\w+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+\(',
                      (project/'outflow/encoder_board.timing.rpt').read_text(),re.M)
    assert timing and all(float(r[3])>=0 for r in timing)
    resources=read(out/'resources.json')
    assert resources['EFX_RAM10']+resources['EFX_DPRAM10']<=256
    assert resources['EFX_DSP48']<=104 and resources['EFX_DSP24']<=4
    programming=(out/'program.log').read_text()
    assert '0x10660A79' in programming and 'finished with JTAG programming' in programming
    return dict(project=str(project),bitstream_sha256=sha(project/'outflow/encoder_board.bit'),
                source_manifest=manifest,resources=resources,timing_rows=timing,
                map_report_sha256=sha(project/'outflow/encoder_board.map.rpt'),
                timing_report_sha256=sha(project/'outflow/encoder_board.timing.rpt'))

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--points',type=int,choices=(23,26),required=True)
    p.add_argument('--photo',type=Path,required=True);p.add_argument('--live',type=Path)
    p.add_argument('--native',type=Path,default=ROOT/'build/instance_full_timing_verified')
    args=p.parse_args();out=args.photo.resolve()
    result=project_check(out,args.points)
    capture=read(out/'photo_pair/capture_report.json');comparison=read(out/'photo_pair/comparison.json')
    display=read(out/'display/image_display.json')
    assert capture['pass_matched_capture'] and display['pass_image_display']
    assert capture['bitstream_sha256']==display['bitstream_sha256']==result['bitstream_sha256']
    assert comparison['mismatches']==0 and comparison['values']==230400
    assert comparison['live_normalization_ids']==list(range(args.points))
    assert comparison['live_channels']==(688 if args.points==26 else 656)
    assert (out/'photo_pair/camera_original.rgbx').read_bytes()==(out/'photo_pair/reference/vectors/frame_rgbx.bin').read_bytes()
    assert sha(out/'photo_pair/camera_original.rgbx')==display['input_rgbx_sha256']
    assert sha(Path(display['image']))==display['image_sha256']
    metrics=display['styled_display']
    assert metrics['command_wait_cycles']==0 and metrics['prefix_mac_cycles']==4974864
    assert metrics['input_checksum']==comparison['input_checksum'] and metrics['output_status']==7
    result.update(points=args.points,live_channels=comparison['live_channels'],
                  photo_comparison=comparison,photo_display=display,
                  matched_capture=capture,compute_ms=metrics['compute_ms'],
                  coefficient_ip_instances=1,statistics_lanes=4,frame_scratch_bases=[0x200000,0x300000])
    if args.points==26:
        native={}
        for stem,logname in [('output','output_delay2.log'),('output_inverted','output_inverted_delay45.log')]:
            stage=Path((args.native/(stem+'_path.txt')).read_text(encoding='utf-8-sig').strip())
            log=(args.native/logname).read_text()
            assert 'FULL_IN_COUNTS coefficients=688 encoder=268800' in log and 'PASS stage4:' in log and '** Fatal:' not in log
            common={n:sha(stage/n) for n in result['source_manifest']['rtl_sha256'] if (stage/n).is_file()}
            assert len(common)>=20 and all(h==result['source_manifest']['rtl_sha256'][n] for n,h in common.items())
            assert sha(stage/'tb_cyclegan_output.sv')==sha(ROOT/'sim/tb_cyclegan_output.sv')
            native[logname]=dict(sha256=sha(args.native/logname),rtl_sha256=common,
                                pass_line=next(l.strip() for l in log.splitlines() if 'PASS stage4:' in l))
        result['native_simulations']=native
        coeff_dir=ROOT/'build/instance_residual_verified'
        coeff_stage=Path((coeff_dir/'coeff_path.txt').read_text(encoding='utf-8-sig').strip())
        assert sha(coeff_stage/'mn_instance_norm_coeff.sv')==sha(ROOT/'rtl/mn_instance_norm_coeff.sv')
        coeff_log=(coeff_dir/'coeff_edge.log').read_text()
        assert 'PASS instance coefficient: 260 cases' in coeff_log and '** Fatal:' not in coeff_log
        result['coefficient_edge_test']=dict(log_sha256=sha(coeff_dir/'coeff_edge.log'),cases=260,max_latency=248)
        compatibility=ROOT/'build/instance_residual_compat_verified/residual_delay2.log'
        if compatibility.exists():
            text=compatibility.read_text()
            assert 'PASS instance residual: coefficients=576 residual_values=345600' in text and '** Fatal:' not in text
            result['residual_18_compatibility']=dict(sha256=sha(compatibility),
                pass_line=next(l.strip() for l in text.splitlines() if 'PASS instance residual:' in l))
        protocol=args.native/'video_protocol'
        protocol_stage=Path((protocol/'unit_sim_path.txt').read_text(encoding='utf-8-sig').strip())
        protocol_hashes={n:sha(protocol_stage/Path(n).name) for n in result['source_manifest']['rtl_sha256'] if n.startswith('video/')}
        assert all(h==result['source_manifest']['rtl_sha256'][n] for n,h in protocol_hashes.items())
        result['video_protocol']={}
        for name,marker in [('image_sim.log','PASS camera fixed image:'),('board_sim.log','PASS camera board protocol:')]:
            text=(protocol/name).read_text()
            assert marker in text and '** Fatal:' not in text
            result['video_protocol'][name]=dict(sha256=sha(protocol/name),pass_line=next(l.strip() for l in text.splitlines() if marker in l))
        result['video_protocol']['rtl_sha256']=protocol_hashes
        if (out/'photo_pair/previous_full26_comparison.json').exists():
            previous=read(out/'photo_pair/previous_full26_comparison.json')
            assert previous['mismatches']==0 and previous['rgb_values']==230400
            assert sha(Path(previous['previous_full26_image']))==previous['previous_full26_sha256']
            assert sha(out/'photo_pair/fpga_styled.png')==previous['fpga_image_sha256']
            result['previous_full26_image_comparison']=previous
        assert args.live,'Full deployment also requires the live camera build'
        live=project_check(args.live.resolve(),26)
        live['streams']={name:read(args.live/name) for name in ('stream_style.json','stream_original.json','stream_restore.json')}
        for report in live['streams'].values():
            assert report['hardware_stream_pass'] and report['bitstream_sha256']==live['bitstream_sha256']
        assert (live['streams']['stream_restore.json']['final']['control_packed']>>10)&7==0
        live['pair']=read(args.live/'live_pair/comparison.json')
        assert live['pair']['mismatches']==0 and live['pair']['live_channels']==688
        result['live_camera']=live
    destination=ROOT/'docs/analysis'/('cyclegan_full_instance_norm.json' if args.points==26 else 'cyclegan_encoder_instance_norm.json')
    destination.write_text(json.dumps(result,indent=2)+'\n')
    (out/'verification.json').write_text(json.dumps(result,indent=2)+'\n')
    print(f'COMPLETE_IN_DEPLOYMENT_PASS points={args.points} channels={comparison["live_channels"]} '+str(destination))

if __name__=='__main__':main()
