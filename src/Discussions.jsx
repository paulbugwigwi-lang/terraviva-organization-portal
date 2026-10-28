import React,{useCallback,useEffect,useMemo,useState} from 'react';
import {MessagesSquare,Plus,Pin,Lock,Unlock,ArrowLeft,Search,Paperclip,Reply,Trash2,Pencil,Building2,Globe} from 'lucide-react';
import {supabase,roles,useRows,uploadMany,Attachments,FilePicker,timeAgo,linkify} from './shared.jsx';

const CATEGORIES={general:'General',project:'Project',question:'Question',idea:'Idea',announcement:'Update',urgent:'Urgent'};
const EMOJIS=['👍','❤️','🎉','👏','🙏','💡'];

function Avatar({person,size=36}){
  const style={width:size,height:size};
  if(person?.photo_url)return <img className="dAvatar" style={style} src={person.photo_url} alt=""/>;
  return <span className="dAvatar placeholder" style={style}>{(person?.full_name||'T').trim().charAt(0).toUpperCase()}</span>;
}

function Reactions({targetType,targetId,reactions,me,onChange}){
  const mine=reactions.filter(r=>r.target_type===targetType&&r.target_id===targetId);
  async function toggle(emoji){
    const own=mine.find(r=>r.user_id===me.id&&r.emoji===emoji);
    const{error}=own?await supabase.from('discussion_reactions').delete().eq('id',own.id):await supabase.from('discussion_reactions').insert({target_type:targetType,target_id:targetId,user_id:me.id,emoji});
    if(error)alert(error.message);else onChange();
  }
  return <div className="reactions">{EMOJIS.map(e=>{const n=mine.filter(r=>r.emoji===e).length;const on=mine.some(r=>r.user_id===me.id&&r.emoji===e);return <button type="button" key={e} className={'react'+(on?' on':'')+(n?'':' empty')} onClick={()=>toggle(e)}>{e}{n>0&&<span>{n}</span>}</button>})}</div>;
}

function Composer({me,onCreated,onCancel,staff}){
  const departments=useMemo(()=>[...new Set(staff.map(s=>s.department).filter(Boolean))].sort(),[staff]);
  const admin=['ceo_chairperson','coo_treasurer','executive_secretary','super_admin'].includes(me.system_role);
  const[f,setF]=useState({title:'',body:'',category:'general',audience:'organization',department:me.department||''}),[files,setFiles]=useState([]),[busy,setBusy]=useState(false);
  async function submit(e){
    e.preventDefault();setBusy(true);
    const payload={title:f.title.trim(),body:f.body.trim(),category:f.category,audience:f.audience,department:f.audience==='department'?f.department:null,author_id:me.id};
    const{data,error}=await supabase.from('discussions').insert(payload).select().single();
    if(error){setBusy(false);return alert(error.message)}
    await uploadMany('discussion',data.id,files,me);
    setBusy(false);onCreated(data.id);
  }
  return <form className="card" onSubmit={submit}>
    <h2>Start a discussion</h2>
    <input required minLength={3} maxLength={200} placeholder="Title — what do you want to discuss?" value={f.title} onChange={e=>setF({...f,title:e.target.value})}/>
    <div className="formRow">
      <select value={f.category} onChange={e=>setF({...f,category:e.target.value})}>{Object.entries(CATEGORIES).map(([k,v])=><option key={k} value={k}>{v}</option>)}</select>
      <select value={f.audience} onChange={e=>setF({...f,audience:e.target.value})}><option value="organization">Everyone in Terraviva</option><option value="department">One department only</option></select>
      {f.audience==='department'&&(admin?<select required value={f.department} onChange={e=>setF({...f,department:e.target.value})}><option value="">Choose department</option>{departments.map(d=><option key={d}>{d}</option>)}</select>:<input readOnly value={me.department||''} placeholder="Your department"/>)}
    </div>
    <textarea placeholder="Describe the topic, share context, questions or decisions needed…" value={f.body} onChange={e=>setF({...f,body:e.target.value})}/>
    <FilePicker files={files} setFiles={setFiles} disabled={busy}/>
    <div className="actions"><button className="primary" disabled={busy||(f.audience==='department'&&!f.department)}>{busy?'Posting…':'Post discussion'}</button><button type="button" onClick={onCancel} disabled={busy}>Cancel</button></div>
  </form>;
}

function Thread({id,me,admin,staff,onBack,onDeleted}){
  const[d,setD]=useState(null),[replies,setReplies]=useState([]),[reactions,setReactions]=useState([]),[missing,setMissing]=useState(false);
  const[body,setBody]=useState(''),[files,setFiles]=useState([]),[replyTo,setReplyTo]=useState(null),[busy,setBusy]=useState(false);
  const[editD,setEditD]=useState(null),[editR,setEditR]=useState(null),[bump,setBump]=useState(0);
  const people=useMemo(()=>Object.fromEntries(staff.map(s=>[s.id,s])),[staff]);
  const load=useCallback(async()=>{
    const{data:disc}=await supabase.from('discussions').select('*').eq('id',id).maybeSingle();
    if(!disc){setMissing(true);return}
    setD(disc);
    const{data:reps}=await supabase.from('discussion_replies').select('*').eq('discussion_id',id).order('created_at');
    setReplies(reps||[]);
    const ids=[id,...(reps||[]).map(r=>r.id)];
    const{data:rx}=await supabase.from('discussion_reactions').select('*').in('target_id',ids);
    setReactions(rx||[]);setBump(b=>b+1);
  },[id]);
  useEffect(()=>{load();const ch=supabase.channel('thread-'+id).on('postgres_changes',{event:'*',schema:'public',table:'discussion_replies',filter:'discussion_id=eq.'+id},load).on('postgres_changes',{event:'*',schema:'public',table:'discussion_reactions'},load).on('postgres_changes',{event:'UPDATE',schema:'public',table:'discussions',filter:'id=eq.'+id},load).subscribe();return()=>{supabase.removeChannel(ch)}},[load,id]);
  if(missing)return <div className="card"><button type="button" onClick={onBack}><ArrowLeft size={15}/> Back</button><p className="muted">This discussion is no longer available or you do not have access.</p></div>;
  if(!d)return <div className="card"><p className="muted">Loading discussion…</p></div>;
  const author=people[d.author_id];const canEdit=d.author_id===me.id||admin;const canReply=!d.locked||admin;
  async function sendReply(e){
    e.preventDefault();if(!body.trim()&&!files.length)return;setBusy(true);
    const{data,error}=await supabase.from('discussion_replies').insert({discussion_id:id,author_id:me.id,body:body.trim(),reply_to_id:replyTo?.id||null}).select().single();
    if(error){setBusy(false);return alert(error.message)}
    await uploadMany('discussion_reply',data.id,files,me);
    setBody('');setFiles([]);setReplyTo(null);setBusy(false);load();
  }
  async function patch(p){const{error}=await supabase.from('discussions').update(p).eq('id',id);if(error)alert(error.message);else load()}
  async function saveEditD(e){e.preventDefault();const{error}=await supabase.from('discussions').update({title:editD.title.trim(),body:editD.body.trim()}).eq('id',id);if(error)alert(error.message);else{setEditD(null);load()}}
  async function delD(){if(!confirm('Delete this whole discussion with all replies and attachment records?'))return;const{error}=await supabase.from('discussions').delete().eq('id',id);if(error)alert(error.message);else onDeleted()}
  async function saveEditR(e){e.preventDefault();const{error}=await supabase.from('discussion_replies').update({body:editR.body.trim()}).eq('id',editR.id);if(error)alert(error.message);else{setEditR(null);load()}}
  async function delR(r){if(!confirm('Delete this reply?'))return;const{error}=await supabase.from('discussion_replies').delete().eq('id',r.id);if(error)alert(error.message);else load()}
  const quoted=r=>replies.find(x=>x.id===r.reply_to_id);
  return <div className="threadView">
    <div className="toolbar"><button type="button" onClick={onBack}><ArrowLeft size={15}/> All discussions</button><div className="actions">
      {admin&&<button type="button" onClick={()=>patch({pinned:!d.pinned})}><Pin size={14}/> {d.pinned?'Unpin':'Pin'}</button>}
      {admin&&<button type="button" onClick={()=>patch({locked:!d.locked})}>{d.locked?<><Unlock size={14}/> Unlock</>:<><Lock size={14}/> Lock</>}</button>}
    </div></div>
    <article className="card threadHead">
      <div className="badges"><span className={'catBadge '+d.category}>{CATEGORIES[d.category]}</span>{d.pinned&&<span className="catBadge pin"><Pin size={11}/> Pinned</span>}{d.locked&&<span className="catBadge lock"><Lock size={11}/> Locked</span>}<span className="aud">{d.audience==='organization'?<><Globe size={12}/> Everyone</>:<><Building2 size={12}/> {d.department}</>}</span></div>
      {editD?<form onSubmit={saveEditD}><input required minLength={3} value={editD.title} onChange={e=>setEditD({...editD,title:e.target.value})}/><textarea value={editD.body} onChange={e=>setEditD({...editD,body:e.target.value})}/><div className="actions"><button className="primary">Save</button><button type="button" onClick={()=>setEditD(null)}>Cancel</button></div></form>:<>
        <h2>{d.title}</h2>
        <div className="byline"><Avatar person={author}/><div><b>{author?.full_name||'Staff'}</b><small>{roles[author?.system_role]||''} · {new Date(d.created_at).toLocaleString()}{d.updated_at>d.created_at&&new Date(d.updated_at)-new Date(d.created_at)>2000?' · edited':''}</small></div></div>
        {d.body&&<p className="postBody">{linkify(d.body)}</p>}</>}
      <Attachments parentType="discussion" parentId={d.id} me={me} canUpload={canEdit} canManage={canEdit} refreshKey={bump}/>
      <Reactions targetType="discussion" targetId={d.id} reactions={reactions} me={me} onChange={load}/>
      {canEdit&&!editD&&<div className="actions"><button type="button" onClick={()=>setEditD({title:d.title,body:d.body})}><Pencil size={13}/> Edit</button><button type="button" className="danger" onClick={delD}><Trash2 size={13}/> Delete</button></div>}
    </article>
    <h3 className="repliesTitle">{replies.length} repl{replies.length===1?'y':'ies'}</h3>
    {replies.map(r=>{const a=people[r.author_id],q=quoted(r),own=r.author_id===me.id;return <article className="card reply" key={r.id} id={'r-'+r.id}>
      <div className="byline"><Avatar person={a} size={32}/><div><b>{a?.full_name||'Staff'}</b><small>{roles[a?.system_role]||''} · {timeAgo(r.created_at)}{r.edited_at?' · edited':''}</small></div></div>
      {q&&<blockquote className="quote"><b>{people[q.author_id]?.full_name||'Staff'}</b> {(q.body||'(attachment)').slice(0,140)}</blockquote>}
      {editR?.id===r.id?<form onSubmit={saveEditR}><textarea value={editR.body} onChange={e=>setEditR({...editR,body:e.target.value})}/><div className="actions"><button className="primary">Save</button><button type="button" onClick={()=>setEditR(null)}>Cancel</button></div></form>:(r.body&&<p className="postBody">{linkify(r.body)}</p>)}
      <Attachments parentType="discussion_reply" parentId={r.id} me={me} canUpload={own} canManage={admin} refreshKey={bump}/>
      <div className="replyFoot"><Reactions targetType="reply" targetId={r.id} reactions={reactions} me={me} onChange={load}/><div className="actions">
        {canReply&&<button type="button" onClick={()=>{setReplyTo(r);document.getElementById('replyBox')?.scrollIntoView({behavior:'smooth',block:'center'})}}><Reply size={13}/> Reply</button>}
        {own&&<button type="button" onClick={()=>setEditR({id:r.id,body:r.body})}><Pencil size={13}/></button>}
        {(own||admin)&&<button type="button" className="danger" onClick={()=>delR(r)}><Trash2 size={13}/></button>}</div></div>
    </article>})}
    {canReply?<form className="card" id="replyBox" onSubmit={sendReply}>
      <h3>Add your reply</h3>
      {replyTo&&<div className="replyingTo">Replying to <b>{people[replyTo.author_id]?.full_name||'Staff'}</b>: {(replyTo.body||'(attachment)').slice(0,80)} <button type="button" onClick={()=>setReplyTo(null)}>Cancel</button></div>}
      <textarea placeholder="Write your reply…" value={body} onChange={e=>setBody(e.target.value)}/>
      <FilePicker files={files} setFiles={setFiles} disabled={busy}/>
      <button className="primary" disabled={busy||(!body.trim()&&!files.length)}>{busy?'Sending…':'Post reply'}</button>
    </form>:<div className="card infoBox"><p><Lock size={14}/> This discussion is locked. Only administrators can reply.</p></div>}
  </div>;
}

export default function Discussions({me,admin,openId,clearOpen}){
  const[rows,setRows]=useState([]),[counts,setCounts]=useState({}),[err,setErr]=useState(''),[staff]=useRows('staff_profiles','full_name');
  const[q,setQ]=useState(''),[cat,setCat]=useState('all'),[composer,setComposer]=useState(false),[active,setActive]=useState(openId||null);
  const people=useMemo(()=>Object.fromEntries(staff.map(s=>[s.id,s])),[staff]);
  const load=useCallback(async()=>{
    const[d,r,a]=await Promise.all([
      supabase.from('discussions').select('*').order('pinned',{ascending:false}).order('last_activity_at',{ascending:false}),
      supabase.from('discussion_replies').select('id,discussion_id'),
      supabase.from('attachments').select('parent_type,parent_id').in('parent_type',['discussion','discussion_reply'])]);
    if(d.error){setErr(d.error.message);return}
    setErr('');setRows(d.data||[]);
    const replyOwner={};const c={};
    (r.data||[]).forEach(x=>{replyOwner[x.id]=x.discussion_id;(c[x.discussion_id]||={replies:0,files:0}).replies++});
    (a.data||[]).forEach(x=>{const did=x.parent_type==='discussion'?x.parent_id:replyOwner[x.parent_id];if(did)(c[did]||={replies:0,files:0}).files++});
    setCounts(c);
  },[]);
  useEffect(()=>{load();const ch=supabase.channel('discussions-list').on('postgres_changes',{event:'*',schema:'public',table:'discussions'},load).on('postgres_changes',{event:'*',schema:'public',table:'discussion_replies'},load).subscribe();return()=>{supabase.removeChannel(ch)}},[load]);
  useEffect(()=>{if(openId)setActive(openId)},[openId]);
  const shown=rows.filter(x=>(cat==='all'||x.category===cat)&&((x.title+' '+x.body+' '+(people[x.author_id]?.full_name||'')).toLowerCase().includes(q.toLowerCase())));
  const close=()=>{setActive(null);clearOpen?.();load()};
  if(active)return <section><Thread id={active} me={me} admin={admin} staff={staff} onBack={close} onDeleted={close}/></section>;
  if(composer)return <section><Composer me={me} staff={staff} onCancel={()=>setComposer(false)} onCreated={id=>{setComposer(false);setActive(id)}}/></section>;
  return <section>
    <div className="card infoBox"><h3><MessagesSquare size={18}/> Discussion board</h3><p>Open conversations for the whole organization or a single department. Share photos, videos, audio and documents, react and reply in threads. Everyone involved is notified of new replies.</p></div>
    <div className="toolbar"><div className="searchBox"><Search size={15}/><input placeholder="Search discussions, people or topics…" value={q} onChange={e=>setQ(e.target.value)}/></div><button className="primary" onClick={()=>setComposer(true)}><Plus size={16}/> New discussion</button></div>
    <div className="chips">{[['all','All'],...Object.entries(CATEGORIES)].map(([k,v])=><button type="button" key={k} className={'chip'+(cat===k?' on':'')} onClick={()=>setCat(k)}>{v}</button>)}</div>
    {err&&<div className="notice">{err}</div>}
    <div className="threadList">{shown.map(x=>{const a=people[x.author_id],c=counts[x.id]||{replies:0,files:0};return <article className={'card threadCard'+(x.pinned?' pinned':'')} key={x.id} onClick={()=>setActive(x.id)} tabIndex={0} onKeyDown={e=>{if(e.key==='Enter')setActive(x.id)}}>
      <Avatar person={a} size={42}/>
      <div className="threadMain">
        <div className="badges"><span className={'catBadge '+x.category}>{CATEGORIES[x.category]}</span>{x.pinned&&<span className="catBadge pin"><Pin size={11}/> Pinned</span>}{x.locked&&<span className="catBadge lock"><Lock size={11}/></span>}<span className="aud">{x.audience==='organization'?<><Globe size={12}/> Everyone</>:<><Building2 size={12}/> {x.department}</>}</span></div>
        <h3>{x.title}</h3>
        {x.body&&<p className="excerpt">{x.body.slice(0,180)}{x.body.length>180?'…':''}</p>}
        <small>{a?.full_name||'Staff'} · active {timeAgo(x.last_activity_at)}</small>
      </div>
      <div className="threadStats"><span title="Replies"><MessagesSquare size={14}/> {c.replies}</span>{c.files>0&&<span title="Attachments"><Paperclip size={14}/> {c.files}</span>}</div>
    </article>})}
    {!shown.length&&!err&&<div className="card"><p className="muted">{rows.length?'No discussions match your filters.':'No discussions yet. Be the first to start one.'}</p></div>}</div>
  </section>;
}
