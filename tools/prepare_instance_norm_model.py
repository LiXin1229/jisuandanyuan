"""Independent integer model: selectable 18, 23, or all 26 same-frame IN points.

Derived from pe10_10/tools/prepare_generator_params.py; that reference tree is
read-only. Encoder/decoder use the original fixed affine coefficients.
"""
from pathlib import Path
import sys
REF=Path(r'C:/Users/Administrator/Desktop/jisuan/pe10_10')
sys.path.append(str(REF/'tools'))
import argparse,hashlib,json,math
import numpy as np
from PIL import Image
from inspect_pth import load_state_dict
from export_first_layer import tensor_values,q88,bn_affine,interleave
from first_layer_reference import requant,tile_bytes
from pack_generator_rom import pack_rom
from export_live_norm import export as export_norm
from live_norm_reference import affine as live_affine
ROOT=REF
cli=argparse.ArgumentParser(description=__doc__)
cli.add_argument('--checkpoint',type=Path,default=ROOT/'netG_B_epoch11.pth')
cli.add_argument('--output',type=Path,default=Path(__file__).resolve().parents[1]/'build/instance_residual_model')
cli.add_argument('--image',type=Path,default=ROOT/'weight/test.jpg')
cli.add_argument('--live-points',type=int,choices=(18,23,26),default=18)
args=cli.parse_args()
live_ids=list(range(5,23)) if args.live_points==18 else list(range(args.live_points))
OUT=args.output.resolve();OUT.mkdir(parents=True,exist_ok=True)
CHECKPOINT=args.checkpoint.resolve();IMAGE=args.image.resolve();words=[];enc=[];blocks=[];dec=[]
raw_norm=export_norm(CHECKPOINT,OUT)
rgb_source=np.asarray(Image.open(IMAGE).convert('RGB'))
assert rgb_source.shape==(240,320,3),'Test image must be 320x240'
a,p,s=load_state_dict(CHECKPOINT)
saturated_inputs={}
for key,tensor in s.items():
 expected_dtype='int64' if key.endswith('.num_batches_tracked') else 'float32'
 assert tensor.storage.dtype.name==expected_dtype,(key,'expected '+expected_dtype)
 values=tensor_values(a,p,s,key)
 assert all(math.isfinite(v) for v in values),(key,'non-finite parameter')
 if key.endswith('.running_var'):assert all(v>=0 for v in values),(key,'negative BN running variance')
 if tensor.storage.dtype.name=='float32':
  clipped=sum(not -32768<=round(v*256)<=32767 for v in values)
  if clipped:saturated_inputs[key]=clipped
def weight(key,shape):
 assert s[key].shape==shape,(key,s[key].shape,shape)
 return np.array([q88(x) for x in tensor_values(a,p,s,key)],dtype=np.int64).reshape(shape)
def bn(key):
 aa,bb=bn_affine(a,p,s,key)
 assert all(-8192<=x<=8191 for x in bb),(key,'beta exceeds DSP bias input')
 return np.array(aa,dtype=np.int64),np.array(bb,dtype=np.int64)
def add(v):
 base=len(words);words.extend(int(x) for x in np.asarray(v).reshape(-1));return base
with a:
 for idx,ci,co in [(1,3,8),(5,8,16),(7,16,32)]:
  w=weight(f'model.{idx}.depthwise'+('.weight' if idx==1 else '.0.weight'),(ci,1,3,3))
  b=dict(layer=idx,cin=ci,cout=co,dw=add(w))
  db=None if idx==1 else bn(f'model.{idx}.depthwise.1')
  if db is not None:b['dw_bn']=add(interleave(*db))
  pw=weight(f'model.{idx}.pointwise'+('.weight' if idx==1 else '.0.weight'),(co,ci,1,1));b['pw']=add(pw)
  pb=bn('model.2' if idx==1 else f'model.{idx}.pointwise.1');b['pw_bn']=add(interleave(*pb))
  enc.append((b,w[:,0],db,pw[:,:,0,0],pb))
 assert len(words)==1067
 for idx in range(9,18):
  w=weight(f'model.{idx}.depthwise.0.weight',(32,1,3,3));b=dict(layer=idx,cin=32,cout=32,dw=add(w))
  db=bn(f'model.{idx}.depthwise.1');b['dw_bn']=add(interleave(*db))
  pw=weight(f'model.{idx}.pointwise.0.weight',(32,32,1,1));b['pw']=add(pw)
  pb=bn(f'model.{idx}.pointwise.1');b['pw_bn']=add(interleave(*pb))
  blocks.append((b,w[:,0],db,pw[:,:,0,0],pb))
 assert len(words)==14027
 for idx,ci,co in [(18,32,16),(21,16,8),(24,8,8)]:
  w=weight(f'model.{idx}.weight',(ci,co,3,3));ab=bn(f'model.{idx+1}')
  base=len(words)
  for oc in range(co):
   for phase in range(4):
    py,px=phase>>1,phase&1
    for ic in range(ci):
     for dy in range(py+1):
      for dx in range(px+1):words.append(int(w[ic,oc,2*(1-dy) if py else 1,2*(1-dx) if px else 1]))
  b=dict(model_index=idx,cin=ci,cout=co,weight_base=base,bn_base=add(interleave(*ab)))
  dec.append((b,w,ab))
 assert len(words)==20427
 final_kernel=s['model.28.weight'].shape[2]
 assert final_kernel in (3,7),'Only 3x3 and 7x7 output convolutions are supported'
 final_w=weight('model.28.weight',(3,8,final_kernel,final_kernel));final_base=add(final_w)
assert len(words)==20427+3*8*final_kernel**2
# Validate all command bounds before emitting a ROM or reference vectors.
acc_bounds=[]
for info,w,db,pw,pb in enc+blocks:
 acc_bounds.extend([int(128*np.abs(w).reshape(w.shape[0],-1).sum(axis=1).max()),
                    int(128*np.abs(pw).sum(axis=1).max())])
 for ab in [db,pb]:
  if ab is not None:acc_bounds.append(int((128*np.abs(ab[0])+16*np.abs(ab[1])).max()))
for info,w,ab in dec:
 for py,px in [(0,0),(0,1),(1,0),(1,1)]:
  ys=[1] if not py else [0,2];xs=[1] if not px else [0,2]
  acc_bounds.append(int(128*np.abs(w[:,:,ys][:,:,:,xs]).sum(axis=(0,2,3)).max()))
 acc_bounds.append(int((128*np.abs(ab[0])+16*np.abs(ab[1])).max()))
acc_bounds.append(int(128*np.abs(final_w).sum(axis=(1,2,3)).max()))
acc_bounds.append(2*128*256)
acc_bounds.append(128*32768+16*32768)
assert max(acc_bounds)<2**23,'Weights exceed signed 24-bit accumulator; widen generator_tile_dsp first'
rom_depth=((len(words)+511)//512)*512
(OUT/'generator_params_q88.mem').write_text('\n'.join(f'{x&65535:04x}' for x in words+[0]*(rom_depth-len(words)))+'\n')
pack_rom(OUT/'generator_params_q88.mem', OUT/'generator_params_packed.mem')
padded=words+[0]*(rom_depth-len(words))
bank_ranges=[(0,16384),(16384,20480),(20480,20992)] if final_kernel==3 else [(0,16384),(16384,20480),(20480,21504),(21504,21632)]
for bank,(lo,hi) in enumerate(bank_ranges):
 (OUT/f'generator_params_bank{bank}.mem').write_text('\n'.join(f'{x&65535:04x}' for x in padded[lo:hi])+'\n')
# Address represents signed Q4.8 in [-8, 8). Output is display-ready uint8.
lut=np.array([round((np.tanh((i-2048)/256)+1)*127.5) for i in range(4096)],dtype=np.uint8)
(OUT/'tanh_u8.mem').write_text('\n'.join(f'{x:02x}' for x in lut)+'\n')
def save_tiles(dest,stem,act):
 co,h,w=act.shape
 tiles=[tile_bytes(act[c,y:y+10,x:x+10]) for c in range(co) for y in range(0,h,10) for x in range(0,w,10)]
 raw=b''.join(tiles);ddr=b''.join(t+bytes(28) for t in tiles)
 np.save(dest/f'{stem}.npy',act)
 (dest/f'{stem}_tiles.bin').write_bytes(raw);(dest/f'{stem}_ddr.bin').write_bytes(ddr)
 (dest/f'{stem}_tiles.mem').write_text('\n'.join(f'{int.from_bytes(t,"little"):0200x}' for t in tiles)+'\n')
 return dict(name=stem,shape=list(act.shape),tiles=len(tiles),values=len(raw),sha256=hashlib.sha256(raw).hexdigest())
def dw(act,w,reflect=False):
 _,h,ww=act.shape;pad=np.pad(act,((0,0),(1,1),(1,1)),mode='reflect' if reflect else 'constant')
 raw=sum(pad[:,r:r+h,c:c+ww]*w[:,r,c,None,None] for r in range(3) for c in range(3))
 return requant(raw)
def norm(act,ab):
 global norm_id
 if norm_id in live_ids:
  result,a,b=live_affine(act,*raw_norm[norm_id])
  norm_records.append(dict(id=norm_id,shape=list(act.shape),a=a.tolist(),b=b.tolist(),
   sums=act.sum(axis=(1,2)).tolist(),squares=(act*act).sum(axis=(1,2)).tolist()))
 else:result=requant(act*ab[0][:,None,None]+ab[1][:,None,None]*16)
 norm_id+=1
 return result
for name,invert in [('vectors',False),('vectors_inverted',True)]:
 norm_id=0;norm_records=[]
 dest=OUT/name;dest.mkdir(exist_ok=True);stats=[]
 rgb=rgb_source
 if invert:rgb=255-rgb
 frame=np.concatenate([rgb,np.zeros((240,320,1),dtype=np.uint8)],axis=2).tobytes()
 (dest/'frame_rgbx.bin').write_bytes(frame)
 (dest/'frame_rgbx.mem').write_text('\n'.join(f'{int.from_bytes(frame[i:i+16],"little"):032x}' for i in range(0,len(frame),16))+'\n')
 act=((rgb.astype(np.int64)-124)>>3).transpose(2,0,1)
 for i,(info,w,db,pw,pb) in enumerate(enc):
  act=dw(act,w,i==0)
  if db is not None:act=np.maximum(norm(act,db),0)
  raw_pw=requant(np.einsum('oc,chw->ohw',pw,act))
  act=norm(raw_pw,pb)
  if i==0:act=np.maximum(act,0)
  co,h,ww=act.shape;act=act.reshape(co,h//2,2,ww//2,2).max(axis=(2,4))
  stats.append(save_tiles(dest,f'encoder{i+1}_q44',act.astype(np.int8)))
 for i,(info,w,db,pw,pb) in enumerate(blocks):
  branch=np.maximum(norm(dw(act,w),db),0)
  branch=norm(requant(np.einsum('oc,chw->ohw',pw,branch)),pb)
  act=np.clip(act+branch,-128,127)
  stats.append(save_tiles(dest,f'block{i+1}_q44',act.astype(np.int8)))
 for i,(info,w,ab) in enumerate(dec):
  ci,h,ww=act.shape;co=w.shape[1];raw=np.zeros((co,2*h,2*ww),dtype=np.int64)
  # Independent scatter definition, deliberately not hardware polyphase indexing.
  for kr in range(3):
   for kc in range(3):
    yy=np.arange(h)*2+kr-1;xx=np.arange(ww)*2+kc-1;vy=(yy>=0)&(yy<2*h);vx=(xx>=0)&(xx<2*ww)
    raw[:,yy[vy,None],xx[None,vx]]+=np.einsum('io,ihw->ohw',w[:,:,kr,kc],act[:,vy][:,:,vx])
  act=np.maximum(norm(requant(raw),ab),0)
  stats.append(save_tiles(dest,f'stage{i+1}_q44',act.astype(np.int8)))
 final_pad=final_kernel//2
 pad=np.pad(act,((0,0),(final_pad,final_pad),(final_pad,final_pad)),mode='reflect')
 raw=sum(np.einsum('oc,chw->ohw',final_w[:,:,r,c],pad[:,r:r+240,c:c+320]) for r in range(final_kernel) for c in range(final_kernel))
 np.save(dest/'final_acc.npy',raw)
 address=np.clip((raw+8)>>4,-2048,2047)+2048
 result=lut[address]
 stats.append(save_tiles(dest,'output_u8',result))
 Image.fromarray(result.transpose(1,2,0)).save(dest/'reference_output.png')
 error=np.abs(result.astype(float)/127.5-1-np.tanh(raw/4096.0))
 (dest/'manifest.json').write_text(json.dumps(dict(layers=stats,output_max_tanh_error=float(error.max()),
  output_mean_tanh_error=float(error.mean()),input_sha256=hashlib.sha256(frame).hexdigest()),indent=2)+'\n')
 print('GENERATOR_REFERENCE_PASS',name,stats[-1],flush=True)
 assert norm_id==26
 (dest/'live_normalization.json').write_text(json.dumps(dict(layers=len(live_ids),ids=live_ids,
  coefficients=norm_records,contract='live_norm_reference.py'),indent=2)+'\n')
manifest=dict(count=len(words),rom_depth=rom_depth,checkpoint=CHECKPOINT.name,
 checkpoint_sha256=hashlib.sha256(CHECKPOINT.read_bytes()).hexdigest(),
 encoder=[x[0] for x in enc],blocks=[x[0] for x in blocks],decoder=[x[0] for x in dec],
 output=dict(model_index=28,cin=8,cout=3,kernel=final_kernel,reflection_pad=final_kernel//2,weight_base=final_base,count=3*8*final_kernel**2),
 rom_banks=[dict(start=lo,depth=hi-lo) for lo,hi in bank_ranges],
 tanh=dict(depth=4096,width=8,input='signed Q4.8; round((acc+8)>>4); clamp [-2048,2047]',
  output='uint8 round((tanh(x)+1)*127.5)',table_sha256=hashlib.sha256((OUT/'tanh_u8.mem').read_bytes()).hexdigest()))
manifest['accumulator']=dict(bits=24,maximum_absolute_bound=max(acc_bounds),residual_add_absolute_bound=65536,
 proof='For every command, 128*sum(abs(Q8.8 weights)); BN adds 16*abs(beta); NORM_ADD bound is 2*128*256=65536. Live affine absolute bound is 128*32768+16*32768=4718592. Covers every int8 input and partial sum.')
manifest['quantization']=dict(weight_format='Q8.8',activation_format='Q4.4',
 input_tensors_with_q88_saturation=saturated_inputs,
 note='Stored BN values and derived affine factors follow the existing Q8.8 saturation rules.')
manifest['reference_image_sha256']=hashlib.sha256(IMAGE.read_bytes()).hexdigest()
manifest['live_normalization_layers']=len(live_ids)
manifest['live_normalization_ids']=live_ids
(OUT/'params_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('GENERATOR_PARAMS_PASS words='+str(len(words)))
