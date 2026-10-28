import React,{useEffect,useRef,useState} from 'react';
import {createClient} from '@supabase/supabase-js';
import {Paperclip,X,FileText,Film,Music,Image as ImageIcon,UploadCloud} from 'lucide-react';

const SUPABASE_URL=import.meta.env.VITE_SUPABASE_URL||'https://fuhocpdvouphbppvjzof.supabase.co';
const SUPABASE_KEY=import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY||import.meta.env.VITE_SUPABASE_ANON_KEY||'sb_publishable_tFWoZ6IGJ0CtLG1bV44VMA_8QnDbTiw';
export const supabase=createClient(SUPABASE_URL,SUPABASE_KEY);
export const roles={ceo_chairperson:'CEO & Chairperson',coo_treasurer:'COO & Treasurer',executive_secretary:'Executive Secretary',department_head:'Department Head',staff:'Staff',super_admin:'Super Admin'};

export function useRows(table,order='created_at'){const[d,setD]=useState([]),[err,setErr]=useState('');const load=async()=>{const{data,error}=await supabase.from(table).select('*').order(order,{ascending:false});if(error)setErr(error.message);else{setD(data||[]);setErr('')}};useEffect(()=>{load()},[]);return[d,load,err]}

/* ---------- helpers ---------- */
export const MAX_FILES=10;
export const MAX_FILE_MB=100;
export function fmtSize(n){if(!n&&n!==0)return '';if(n<1024)return n+' B';if(n<1048576)return (n/1024).toFixed(0)+' KB';return (n/1048576).toFixed(1)+' MB'}
export function timeAgo(d){const s=Math.max(1,Math.floor((Date.now()-new Date(d).getTime())/1000));if(s<60)return 'just now';const m=Math.floor(s/60);if(m<60)return m+' min ago';const h=Math.floor(m/60);if(h<24)return h+' h ago';const dd=Math.floor(h/24);if(dd<7)return dd+' d ago';return new Date(d).toLocaleDateString()}
export function linkify(text){return String(text||'').split(/(https?:\/\/[^\s<]+)/g).map((p,i)=>/^https?:\/\//.test(p)?<a key={i} href={p} target="_blank" rel="noreferrer noopener">{p}</a>:p)}
function FileGlyph({mime,size=18}){if((mime||'').startsWith('image/'))return <ImageIcon size={size}/>;if((mime||'').startsWith('video/'))return <Film size={size}/>;if((mime||'').startsWith('audio/'))return <Music size={size}/>;return <FileText size={size}/>}

/* ---------- Cloudinary upload (with progress) ---------- */
const CLOUDINARY_CLOUD_NAME='haxv2p4m';
const CLOUDINARY_UPLOAD_PRESET='terraviva_unsigned';

export function uploadToCloudinary(file,onProgress){
  return new Promise((resolve,reject)=>{
    const fd=new FormData();
    fd.append('file',file);
    fd.append('upload_preset',CLOUDINARY_UPLOAD_PRESET);
    const xhr=new XMLHttpRequest();
    xhr.open('POST',`https://api.cloudinary.com/v1_1/${CLOUDINARY_CLOUD_NAME}/auto/upload`);
    if(onProgress)xhr.upload.onprogress=e=>{if(e.lengthComputable)onProgress(Math.round(e.loaded/e.total*100))};
    xhr.onerror=()=>reject(new Error('Network error while uploading '+file.name));
    xhr.onload=()=>{let data={};try{data=JSON.parse(xhr.responseText)}catch{}if(xhr.status>=200&&xhr.status<300)resolve(data);else reject(new Error(data?.error?.message||'Cloudinary upload failed'))};
    xhr.send(fd);
  });
}

export function cloudinaryDownloadUrl(url,fileName){
  const base=(fileName||'file').replace(/\.[^/.]+$/,'');
  return url.replace('/upload/','/upload/fl_attachment:'+encodeURIComponent(base)+'/');
}

const emit=detail=>window.dispatchEvent(new CustomEvent('tv-upload',{detail}));

/* Uploads several files one after another and records each as an attachment row. Failures are reported once. */
export async function uploadMany(parentType,parentId,files,me){
  const list=Array.from(files||[]);
  if(!list.length||!parentId)return {ok:0,failed:[]};
  const failed=[];let ok=0;
  for(let i=0;i<list.length;i++){
    const file=list[i];
    emit({state:'progress',index:i+1,total:list.length,percent:0,name:file.name});
    try{
      const cloud=await uploadToCloudinary(file,percent=>emit({state:'progress',index:i+1,total:list.length,percent,name:file.name}));
      const{error}=await supabase.from('attachments').insert({parent_type:parentType,parent_id:parentId,file_name:file.name,storage_path:cloud.public_id,url:cloud.secure_url,mime_type:file.type||'',size_bytes:file.size,uploaded_by:me.id});
      if(error)throw error;ok++;
    }catch(e){failed.push({file,message:e.message||'Upload failed'})}
  }
  emit({state:'done'});
  if(failed.length)alert('These files could not be attached:\n'+failed.map(f=>'• '+f.file.name+' — '+f.message).join('\n'));
  return {ok,failed};
}
export async function uploadAttachment(parentType,parentId,file,me){const r=await uploadMany(parentType,parentId,file?[file]:[],me);return {error:r.failed[0]?new Error(r.failed[0].message):null}}

export function UploadToast(){
  const[s,setS]=useState(null);
  useEffect(()=>{const h=e=>setS(e.detail.state==='done'?null:e.detail);window.addEventListener('tv-upload',h);return()=>window.removeEventListener('tv-upload',h)},[]);
  if(!s)return null;
  return <div className="uploadToast" role="status"><UploadCloud size={18}/><div><b>Uploading {s.index} of {s.total}</b><small>{s.name}</small><div className="bar"><i style={{width:s.percent+'%'}}/></div></div><span>{s.percent}%</span></div>;
}

/* ---------- preview ---------- */
export function renderPreview(p){
  const mime=p.mime_type||'';
  if(mime.startsWith('image/')) return <img src={p.url} alt={p.file_name} style={{maxWidth:'100%',display:'block',margin:'0 auto'}}/>;
  if(mime.startsWith('video/')) return <video src={p.url} controls style={{maxWidth:'100%'}}/>;
  if(mime.startsWith('audio/')) return <audio src={p.url} controls style={{width:'100%'}}/>;
  if(mime==='application/pdf') return <iframe src={p.url} title={p.file_name} style={{width:'100%',height:'70vh',border:0}}/>;
  return <iframe src={'https://docs.google.com/gview?url='+encodeURIComponent(p.url)+'&embedded=true'} title={p.file_name} style={{width:'100%',height:'70vh',border:0}}/>;
}

/* ---------- multi-file picker (drag & drop, thumbnails) ---------- */
function Thumb({file}){
  const[u,setU]=useState('');
  useEffect(()=>{if(!file.type.startsWith('image/'))return;const x=URL.createObjectURL(file);setU(x);return()=>URL.revokeObjectURL(x)},[file]);
  return u?<img src={u} alt="" className="pickThumb"/>:<span className="pickThumb glyph"><FileGlyph mime={file.type}/></span>;
}
export function FilePicker({files,setFiles,disabled,label='Attach files'}){
  const ref=useRef(null);const[drag,setDrag]=useState(false);
  function add(list){
    const next=[...files];
    for(const f of Array.from(list||[])){
      if(f.size>MAX_FILE_MB*1048576){alert(f.name+' is larger than '+MAX_FILE_MB+' MB.');continue}
      if(next.some(x=>x.name===f.name&&x.size===f.size))continue;
      if(next.length>=MAX_FILES){alert('You can attach up to '+MAX_FILES+' files at a time.');break}
      next.push(f);
    }
    setFiles(next);
  }
  return <div className={'filePicker'+(drag?' drag':'')} onDragOver={e=>{e.preventDefault();setDrag(true)}} onDragLeave={()=>setDrag(false)} onDrop={e=>{e.preventDefault();setDrag(false);if(!disabled)add(e.dataTransfer.files)}}>
    <button type="button" className="pickBtn" disabled={disabled} onClick={()=>ref.current?.click()}><Paperclip size={15}/> {label}</button>
    <small>Photos, videos, audio, PDF, Word, Excel… up to {MAX_FILES} files, {MAX_FILE_MB} MB each. You can also drop files here.</small>
    <input ref={ref} type="file" multiple hidden onChange={e=>{add(e.target.files);e.target.value=''}}/>
    {files.length>0&&<div className="pickList">{files.map((f,i)=><div className="pickItem" key={f.name+f.size+i}><Thumb file={f}/><span className="pickName">{f.name}<small>{fmtSize(f.size)}</small></span><button type="button" className="pickRemove" disabled={disabled} onClick={()=>setFiles(files.filter((_,j)=>j!==i))} title="Remove"><X size={14}/></button></div>)}</div>}
  </div>;
}

/* ---------- attachments of a record ---------- */
export function Attachments({parentType,parentId,me,canUpload,canManage,refreshKey}){
  const[rows,setRows]=useState([]),[files,setFiles]=useState([]),[busy,setBusy]=useState(false),[preview,setPreview]=useState(null),[adding,setAdding]=useState(false);
  const load=async()=>{if(!parentId)return;const{data}=await supabase.from('attachments').select('*').eq('parent_type',parentType).eq('parent_id',parentId).order('created_at');setRows(data||[])};
  useEffect(()=>{load()},[parentId,refreshKey]);
  async function upload(){if(!files.length)return;setBusy(true);const{failed}=await uploadMany(parentType,parentId,files,me);setBusy(false);setFiles(failed.map(f=>f.file));if(!failed.length)setAdding(false);load()}
  async function open(a){if(a.url)return setPreview({...a,url:a.url});const{data,error}=await supabase.storage.from('portal-attachments').createSignedUrl(a.storage_path,3600);if(error)return alert(error.message);setPreview({...a,url:data.signedUrl})}
  async function download(a){if(a.url)return window.open(cloudinaryDownloadUrl(a.url,a.file_name),'_blank');const{data,error}=await supabase.storage.from('portal-attachments').createSignedUrl(a.storage_path,300,{download:a.file_name});if(error)return alert(error.message);window.open(data.signedUrl,'_blank')}
  async function del(a){if(!confirm('Delete this file?'))return;if(!a.url)await supabase.storage.from('portal-attachments').remove([a.storage_path]);const{error}=await supabase.from('attachments').delete().eq('id',a.id);if(error)alert(error.message);else load()}
  if(!parentId)return null;
  if(!rows.length&&!canUpload)return null;
  const images=rows.filter(a=>(a.mime_type||'').startsWith('image/')&&a.url);
  const others=rows.filter(a=>!images.includes(a));
  return <div className="attachBox">
    {images.length>0&&<div className="imageGrid">{images.map(a=><button type="button" key={a.id} className="imageTile" onClick={()=>open(a)} title={a.file_name}><img src={a.url.replace('/upload/','/upload/c_fill,w_320,h_240,q_auto/')} alt={a.file_name} loading="lazy" onError={e=>{if(!e.target.dataset.f){e.target.dataset.f='1';e.target.src=a.url}}}/>{(a.uploaded_by===me.id||canManage)&&<span className="tileDel" role="button" onClick={e=>{e.stopPropagation();del(a)}} title="Delete"><X size={13}/></span>}</button>)}</div>}
    {others.map(a=><div className="attachRow" key={a.id}>
      <span className="attachGlyph"><FileGlyph mime={a.mime_type}/></span>
      <span className="attachName">{a.file_name}{a.size_bytes?<small>{fmtSize(a.size_bytes)}</small>:null}</span>
      <div className="actions">
        <button type="button" onClick={()=>open(a)}>Open</button>
        <button type="button" onClick={()=>download(a)}>Download</button>
        {(a.uploaded_by===me.id||canManage)&&<button type="button" className="danger" onClick={()=>del(a)}>Delete</button>}
      </div>
    </div>)}
    {images.length>0&&<div className="actions"><small className="muted">{images.length} photo{images.length===1?'':'s'} · click to enlarge</small></div>}
    {canUpload&&(adding||files.length>0?<div className="addBox"><FilePicker files={files} setFiles={setFiles} disabled={busy}/><div className="actions"><button type="button" className="primary" disabled={busy||!files.length} onClick={upload}>{busy?'Uploading…':'Upload '+files.length+' file'+(files.length===1?'':'s')}</button><button type="button" disabled={busy} onClick={()=>{setFiles([]);setAdding(false)}}>Cancel</button></div></div>:<button type="button" className="pickBtn" onClick={()=>setAdding(true)}><Paperclip size={15}/> Add files</button>)}
    {preview&&<div className="previewOverlay" onClick={()=>setPreview(null)}>
      <div className="previewBox" onClick={e=>e.stopPropagation()}>
        <div className="previewHeader"><b>{preview.file_name}</b><div className="actions"><button type="button" onClick={()=>download(preview)}>Download</button><button type="button" onClick={()=>setPreview(null)}>Close</button></div></div>
        {renderPreview(preview)}
      </div>
    </div>}
  </div>;
}
