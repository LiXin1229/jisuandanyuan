"""Compare verified residual-only FPGA output with the original BN ablation.

Offline only: preserves the displayed FPGA frame and all deployment RTL.
"""
from pathlib import Path
from datetime import datetime, timezone
import argparse, hashlib, json, runpy, subprocess, sys
import numpy as np
from PIL import Image

ROOT=Path(__file__).resolve().parents[1]
REF=Path(r'C:/Users/Administrator/Desktop/jisuan/pe10_10')


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def metrics(a,b):
    d=a.astype(np.int32)-b.astype(np.int32)
    return dict(values=int(d.size),mismatches=int(np.count_nonzero(d)),
                differing_pixels=int(np.any(d!=0,axis=2).sum()),
                mae_u8=float(np.abs(d).mean()),maximum_difference=int(np.abs(d).max()),
                mean_rgb=a.mean((0,1)).tolist())


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=ROOT/'build/instance_norm_comparison')
    args=parser.parse_args();out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
    image=REF/'camera_original.png';checkpoint=REF/'netG_B_epoch11.pth'
    source=REF/'analysis/analyze_normalization_choices_20261008.py'
    for folder,count in [('full',26),('encoder_residual',23)]:
        with (out/(folder+'_export.log')).open('w') as log:
            subprocess.run([sys.executable,'-B',str(REF/'tools/prepare_generator_params.py'),
                '--image',str(image),'--output',str(out/folder),'--live-normalization-layers',str(count)],
                stdout=log,stderr=subprocess.STDOUT,check=True)
    model=runpy.run_path(str(source))
    p=model['load_parameters'](checkpoint)
    q={k:model['quantize_q88'](v) for k,v in p.items()}
    archive,prefix,state=model['load_state_dict'](checkpoint)
    with archive:
        fixed={key:tuple(np.asarray(v,dtype=np.int64) for v in model['bn_affine'](archive,prefix,state,key))
               for key in model['BN_KEYS']}
    rgb=np.asarray(Image.open(image).convert('RGB'))
    board_dir=ROOT/'build/video_image_verified/photo_pair'
    actual=np.asarray(Image.open(board_dir/'fpga_styled.png').convert('RGB'))
    input_rgbx=np.frombuffer((board_dir/'camera_original.rgbx').read_bytes(),np.uint8).reshape(240,320,4)
    assert np.array_equal(input_rgbx[:,:,:3],rgb) and not input_rgbx[:,:,3].any()
    assert sha(ROOT/'tools/live_norm_reference.py')==sha(REF/'tools/live_norm_reference.py')
    residual=tuple(range(5,23))
    cases=[('residual18','当前板端：残差18点',residual),
           ('encoder_residual23','补齐编码器：23点',tuple(range(23))),
           ('residual_decoder21','补齐转置卷积：21点',tuple(range(5,26))),
           ('full26','全部26点',tuple(range(26)))]
    outputs={};records={}
    for name,title,points in cases:
        outputs[name],records[name]=model['infer'](rgb,q,fixed,set(points))
        Image.fromarray(outputs[name]).save(out/(name+'.png'))
    assert np.array_equal(outputs['residual18'],actual),'Original ablation does not reproduce FPGA'
    # Check the exact original side-by-side artifact the user remembered.
    old=REF/'analysis/normalization_choices_20261008_final/phone_test'
    historical={}
    for name,stem in [('residual18','residual'),('encoder_residual23','prefix_23'),('full26','all')]:
        historical[name]=metrics(outputs[name],np.asarray(Image.open(old/(stem+'.png')).convert('RGB')))
        assert historical[name]['mismatches']==0,('Old comparison artifact differs',name)
    # Independently exported full/prefix references must agree as well.
    for name,folder in [('full26','full'),('encoder_residual23','encoder_residual')]:
        reference=out/folder/'vectors/reference_output.png'
        assert np.array_equal(outputs[name],np.asarray(Image.open(reference).convert('RGB')))
        assert sha(out/folder/'generator_params_q88.mem')==sha(board_dir/'reference/generator_params_q88.mem')
    comparisons={name:metrics(outputs[name],outputs['full26']) for name,_,_ in cases}
    coefficient_changes=[]
    for a,b in zip(records['residual18'],records['full26']):
        changed_a=sum(x!=y for x,y in zip(a['a'],b['a']))
        changed_b=sum(x!=y for x,y in zip(a['b'],b['b']))
        coefficient_changes.append(dict(id=a['id'],key=a['key'],current_mode=a['mode'],
            full_mode=b['mode'],channels=len(a['a']),changed_a=changed_a,changed_b=changed_b,
            current_mean_a=float(np.mean(a['a'])),full_mean_a=float(np.mean(b['a'])),
            current_mean_b=float(np.mean(a['b'])),full_mean_b=float(np.mean(b['b']))))
    float_same_tanh,float_records=model['run_integer'](rgb,p,fixed,True,False)
    script_panel4,_=model['run_integer'](rgb,p,fixed,True,True)
    Image.fromarray(script_panel4).save(out/'lianghua_panel4_numpy.png')
    panels=[('同一张输入图','同一epoch11权重，输入像素与板端回读一致',rgb)]
    for name,title,_ in cases:
        panels.append((title,f"与全26点平均差 {comparisons[name]['mae_u8']:.3f}/255",outputs[name]))
    panels.append(('原脚本第4图：NumPy重现','另含最终卷积Q4.4和Tanh Q4.4量化',script_panel4))
    model['sheet'](out/'comparison.png',panels,'当前板端与原工程完整26点：同图、同权重对比',columns=3)
    first=records['residual18'][0];complete=records['full26'][0];channel=1
    bn0_diagnostic=dict(channel_zero_based=channel,
        running_variance_float=float(p['model.2.running_var'][channel]),
        running_variance_q88=int(q['model.2.running_var'][channel]),
        frame_variance=float(first['input_std'][channel]**2),
        fixed_a_q88=first['a'][channel],live_a_q88=complete['a'][channel],
        fixed_b_q88=first['b'][channel],live_b_q88=complete['b'][channel],
        fixed_int8_limit_fraction=first['output_at_int8_limit'],
        live_int8_limit_fraction=complete['output_at_int8_limit'])
    result=dict(timestamp_utc=datetime.now(timezone.utc).isoformat(),
        input=str(image),input_sha256=sha(image),checkpoint_sha256=sha(checkpoint),
        verified_fpga_output_sha256=sha(board_dir/'fpga_styled.png'),
        fpga_matches_original_residual18=True,historical_artifact_matches=historical,
        identical_integer_normalization_contract=True,
        cases=[dict(name=n,title=t,live_ids=list(ids),**comparisons[n]) for n,t,ids in cases],
        coefficient_changes=coefficient_changes,
        missing_normalization_records={n:[r for r in rows if r['id']<5 or r['id']>=23]
                                       for n,rows in records.items()},
        first_normalization_diagnostic=bn0_diagnostic,
        coefficient_saturation_channels={n:sum(r['affine_saturated'] for r in rows) for n,rows in records.items()},
        float_coefficient_same_tanh_vs_exact26=metrics(float_same_tanh,outputs['full26']),
        lianghua_panel4_numpy_vs_exact26=metrics(script_panel4,outputs['full26']),
        float_coefficient_caveat='NumPy float32 reductions; this is not a PyTorch bit-identity claim',
        source_sha256={str(x):sha(x) for x in [source,REF/'tools/prepare_generator_params.py',
            REF/'tools/analyze_epoch11_quantization.py',ROOT/'tools/live_norm_reference.py',Path(__file__)]},
        board_action='none; HDMI remains the previously frozen residual-only output')
    (out/'analysis.json').write_text(json.dumps(result,indent=2)+'\n')
    (ROOT/'docs/analysis/cyclegan_instance_norm_difference.json').write_text(json.dumps(result,indent=2)+'\n')
    print('INSTANCE_NORM_DIFFERENCE_PASS '+json.dumps(comparisons),flush=True)
    print('FLOAT_COEFFICIENT_SAME_TANH '+json.dumps(result['float_coefficient_same_tanh_vs_exact26']),flush=True)
    print('LIANGHUA_PANEL4 '+json.dumps(result['lianghua_panel4_numpy_vs_exact26']),flush=True)


if __name__=='__main__':main()
