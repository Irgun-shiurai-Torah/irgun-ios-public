// Lecture Follow targets for the native iOS watch view and audio sheet.
export const VALID_FOLLOW_KEY=/^[A-Za-z0-9_\-\u0590-\u05ff]{1,160}$/;

export function normalizeFollowSpeakerName(value) {
  return String(value||'').normalize('NFKD')
    .replace(/[\u0591-\u05c7\u0300-\u036f]/g,'')
    .replace(/^(?:(?:Rabbi|Rav|HaRav|Harav|Reb|הרב|רבי|רב|ר[׳'])\s+)+/i,'')
    .toLowerCase().replace(/[^a-z0-9\u0590-\u05ff]+/g,' ').trim().replace(/\s+/g,' ');
}

function looseName(value) {
  return String(value||'').normalize('NFKD')
    .replace(/[\u0591-\u05c7\u0300-\u036f]/g,'')
    .toLowerCase().replace(/[^a-z0-9\u0590-\u05ff]+/g,' ').trim().replace(/\s+/g,' ');
}

export function fallbackSpeakerFollowKey(name) {
  const slug=normalizeFollowSpeakerName(name).replace(/\s+/g,'-').slice(0,150);
  return slug ? 'auto-'+slug : '';
}

export function followVerb(following,hebrew=false) {
  return hebrew ? (following?'במעקב':'עקוב') : (following?'Following':'Follow');
}

export function lectureFollowTargets(item, {speakerById=new Map(),topicById=new Map(),speakerAliasToId=new Map()}={}) {
  if (!item) return [];
  const result=[];
  const seen=new Set();
  const names=[item.speakerHe,item.speakerEn,item.speaker,item.rabbi,item.lecturer,item._speakerLabel]
    .map(x=>String(x||'').trim()).filter(Boolean);
  const add=(type,key,labelEn,labelHe)=>{
    const k=String(key||'').trim();
    if (!VALID_FOLLOW_KEY.test(k)) return;
    const en=String(labelEn||labelHe||'').trim(),he=String(labelHe||labelEn||'').trim();
    if (!en && !he) return;
    const identity=type+':'+k;
    if (seen.has(identity)) return;
    seen.add(identity);
    result.push({type,key:k,labelEn:en,labelHe:he});
  };
  const ids=[...new Set([
    ...(Array.isArray(item._speakerIds)?item._speakerIds:[]),
    ...(Array.isArray(item.speakerIds)?item.speakerIds:[]),
    item.speakerId
  ].map(x=>String(x||'').trim()).filter(Boolean))];

  if (!ids.length) for (const name of names) {
    if (/\s+[/&]\s+/.test(name)) continue;
    const canonical=speakerAliasToId.get(normalizeFollowSpeakerName(name))
      || speakerAliasToId.get(looseName(name));
    ids.push(String(canonical||fallbackSpeakerFollowKey(name)));
    break;
  }

  for (const speakerId of ids) {
    const speaker=speakerById.get(String(speakerId));
    const en=speaker?.displayEn||speaker?.nameEn||item.speakerEn||item.speaker||item._speakerLabel||item.speakerHe;
    const he=speaker?.displayHe||speaker?.nameHe||item.speakerHe||item.speaker||item._speakerLabel||item.speakerEn;
    let key=speakerId;
    if (!VALID_FOLLOW_KEY.test(key)) {
      const raw=String(speakerId).replace(/^auto-speaker:/i,'');
      key=fallbackSpeakerFollowKey(raw||he||en);
    }
    add('speaker',key,en,he);
  }

  const topicId=String(item._topicId||item.topicId||'').trim();
  const topic=topicById.get(topicId);
  if (topicId) add('topic',topicId,topic?.en||item.topicEn||item.topic||item._topicLabel,
    topic?.he||item.topicHe||item.topic||item._topicLabel);
  return result;
}

export function isFollowTargetActive(target,follows) {
  if (!target||!follows) return false;
  if (follows.has(target.type+':'+target.key)) return true;
  if (target.type!=='speaker'||!target.key.startsWith('auto-')) return false;
  const names=[target.labelEn,target.labelHe].map(normalizeFollowSpeakerName).filter(Boolean);
  for (const item of follows.values()) {
    if (item?.type!=='speaker') continue;
    const known=[item.labelEn,item.labelHe].map(normalizeFollowSpeakerName);
    if (names.some(name=>known.includes(name))) return true;
  }
  return false;
}
