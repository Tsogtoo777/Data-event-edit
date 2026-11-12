-- DRAFT / NOT YET EXECUTED IN PRODUCTION
-- Snapshot of current public.ets_edit_event_e22 plus exact-adjacency checks for
-- inserts into a previously empty interval. Does not change the event data
-- or invent fractional/whole seconds. Supports preview + confirmed save.
-- Test against the current live function before applying; rebase if it changed.

CREATE OR REPLACE FUNCTION public.ets_edit_event_e22(p_mode text, p_operation text, p_input jsonb, p_expected jsonb DEFAULT NULL::jsonb, p_request uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
 src public.equipment_events%ROWTYPE; prev public.equipment_events%ROWTYPE;
 nxt public.equipment_events%ROWTYPE; eqrow public.equipment%ROWTYPE;
 proposed public.equipment_events%ROWTYPE;
 a timestamptz; b timestamptz; n integer; plan jsonb; changes jsonb:='[]'::jsonb;
 original jsonb; leftrow jsonb; rightrow jsonb; inserted jsonb;
 saved public.ets_event_changes_e2%ROWTYPE; v_result jsonb; cols text; eq text; new_state text; auto_end boolean:=false; next_boundary jsonb;
BEGIN
 IF auth.uid() IS NULL OR lower(coalesce(auth.jwt()->'app_metadata'->>'role','')) NOT IN ('event_editor','master','dispatcher','management','admin') THEN RAISE EXCEPTION 'Засах эрх хүрэхгүй'; END IF;
 IF p_mode IS NULL OR p_mode NOT IN ('preview','save') OR p_operation IS NULL OR p_operation NOT IN ('insert','cancel') OR jsonb_typeof(p_input) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Хүсэлтийн утга буруу'; END IF;
 SET LOCAL lock_timeout='8s';
 -- Same event-table -> equipment lock order as Q6/Q7. Locks serialize direct writes too.
 LOCK TABLE public.equipment_events IN SHARE ROW EXCLUSIVE MODE;
 IF p_mode='save' THEN
  IF p_request IS NULL OR p_expected IS NULL THEN RAISE EXCEPTION 'Урьдчилсан шалгалт, хүсэлтийн ID шаардлагатай'; END IF;
  SELECT * INTO saved FROM public.ets_event_changes_e2 WHERE request_id=p_request;
  IF FOUND THEN
   IF saved.actor_id<>auth.uid() OR saved.operation<>p_operation OR saved.input IS DISTINCT FROM p_input OR saved.plan IS DISTINCT FROM p_expected THEN RAISE EXCEPTION 'Хүсэлтийн ID өөр үйлдэлд ашиглагдсан'; END IF;
   RETURN saved.result||jsonb_build_object('replayed',true);
  END IF;
 END IF;
 IF length(trim(coalesce(p_input->>'reason','')))<1 OR length(p_input->>'reason')>4000 THEN RAISE EXCEPTION 'Өөрчлөх шалтгааныг бичнэ үү (4000 тэмдэгт хүртэл)'; END IF;
 IF p_operation='insert' THEN
  proposed:=jsonb_populate_record(NULL::public.equipment_events,p_input->'event');
  eq:=proposed.equipment_id::text; a:=proposed.start_time; b:=proposed.end_time;
  auto_end:=b IS NULL;
  IF a IS NULL OR NOT isfinite(a) OR a>clock_timestamp() THEN RAISE EXCEPTION 'Эхлэх цаг буруу эсвэл ирээдүйд байна'; END IF;
  IF b IS NOT NULL AND (NOT isfinite(b) OR b<=a OR b>clock_timestamp()) THEN RAISE EXCEPTION 'Дуусах цаг эхлэлээс хойш, одооноос өмнө байна'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.status_types WHERE name=proposed.status) THEN RAISE EXCEPTION 'Төлөв лавлахад алга'; END IF;
  IF proposed.smu<0 OR proposed.km<0 OR proposed.smu::text IN ('NaN','Infinity','-Infinity') OR proposed.km::text IN ('NaN','Infinity','-Infinity') THEN RAISE EXCEPTION 'Моточаг / км утга буруу'; END IF;
 ELSE
  SELECT * INTO src FROM public.equipment_events WHERE id::text=p_input->>'id' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Бүртгэл олдсонгүй'; END IF;
  eq:=src.equipment_id::text;
 END IF;
 SELECT * INTO eqrow FROM public.equipment WHERE id::text=eq FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Техник олдсонгүй'; END IF;
 IF EXISTS(SELECT 1 FROM public.equipment_events WHERE equipment_id::text=eq AND (start_time IS NULL OR NOT isfinite(start_time) OR (end_time IS NOT NULL AND (NOT isfinite(end_time) OR end_time<=start_time)))) THEN RAISE EXCEPTION 'Энэ техникийн буруу хугацаатай бүртгэлийг эхлээд засна уу'; END IF;
 SELECT count(*) INTO n FROM public.equipment_events WHERE equipment_id::text=eq AND end_time IS NULL;
 IF n>1 THEN RAISE EXCEPTION 'Олон нээлттэй төлөв байна. Эхлээд шалгана уу'; END IF;
 IF p_operation='insert' THEN
  IF auto_end THEN
   -- Full server lookup, independent of the UI's most-recent-1000-row limit.
   SELECT * INTO nxt FROM public.equipment_events WHERE equipment_id::text=eq AND start_time>a ORDER BY start_time,id LIMIT 1 FOR UPDATE;
   IF FOUND THEN
    b:=nxt.start_time; next_boundary:=to_jsonb(nxt);
    IF b>clock_timestamp() THEN RAISE EXCEPTION 'Дараагийн төлөв ирээдүйн цагтай. Эхлээд цагийг шалгана уу'; END IF;
   ELSE b:=NULL;
   END IF;
  END IF;
  SELECT count(*) INTO n FROM public.equipment_events WHERE equipment_id::text=eq AND (b IS NULL OR start_time<b) AND (end_time IS NULL OR end_time>a);
  IF n>1 THEN RAISE EXCEPTION 'Олон төлөв дамнасан хугацаа байна. Нэг төлөвийн дотор хугацаа сонгоно уу'; END IF;
  -- 0 SECOND RULE: do not create a residual gap when inserting between known events.
  -- This function runs in both preview and save; no timestamp rounding or +1/-1 seconds.
  IF n=0 THEN
   SELECT * INTO prev FROM public.equipment_events
     WHERE equipment_id::text=eq AND start_time<a
     ORDER BY start_time DESC,id DESC LIMIT 1 FOR UPDATE;
   SELECT * INTO nxt FROM public.equipment_events
     WHERE equipment_id::text=eq AND start_time>=a
     ORDER BY start_time,id LIMIT 1 FOR UPDATE;
   IF prev.id IS NOT NULL AND prev.end_time IS DISTINCT FROM a THEN
    RAISE EXCEPTION 'Өмнөх төлөвийн дууссан цаг = шинэ төлөвийн эхэлсэн цаг байх ёстой. Завсар үлдээж болохгүй';
   END IF;
   IF nxt.id IS NOT NULL AND b IS DISTINCT FROM nxt.start_time THEN
    RAISE EXCEPTION 'Шинэ төлөвийн дууссан цаг = дараагийн төлөвийн эхэлсэн цаг байх ёстой. Завсар үлдээж болохгүй';
   END IF;
   IF nxt.id IS NULL AND b IS NOT NULL THEN
    RAISE EXCEPTION 'Дараагийн төлөвгүй бол шинэ төлөв нээлттэй үргэлжлэх ёстой';
   END IF;
  END IF;
  IF n=1 THEN
   SELECT * INTO src FROM public.equipment_events WHERE equipment_id::text=eq AND (b IS NULL OR start_time<b) AND (end_time IS NULL OR end_time>a) FOR UPDATE;
   IF a<src.start_time OR (NOT auto_end AND src.end_time IS NOT NULL AND b>src.end_time) THEN RAISE EXCEPTION 'Шинэ хугацаа хуучин төлөвийн хилээс давсан. Нэг төлөвийн дотор сонгоно уу'; END IF;
   IF a=src.start_time AND (b IS NULL OR (src.end_time IS NOT NULL AND b>=src.end_time)) THEN RAISE EXCEPTION 'Бүх хугацааг солих бол Засах үйлдлийг ашиглана уу'; END IF;
   IF EXISTS(SELECT 1 FROM public.equipment_events e WHERE e.equipment_id=src.equipment_id AND e.id<>src.id AND (src.end_time IS NULL OR e.start_time<src.end_time) AND (e.end_time IS NULL OR e.end_time>src.start_time)) THEN RAISE EXCEPTION 'Хуучин мөр өөр төлөвтэй давхардалтай. Эхлээд давхардлыг засна уу'; END IF;
   original:=to_jsonb(src);
   IF a>src.start_time THEN
    leftrow:=original||jsonb_build_object('end_time',a);
    changes:=changes||jsonb_build_array(jsonb_build_object('kind','update','before',original,'after',leftrow));
    IF b IS NOT NULL AND (src.end_time IS NULL OR b<src.end_time) THEN
     rightrow:=(original-ARRAY['id','created_at','updated_at'])||jsonb_build_object('start_time',b);
     changes:=changes||jsonb_build_array(jsonb_build_object('kind','resume','before',NULL,'after',rightrow));
    END IF;
   ELSE
    -- Keep the source ID on the right remainder; never leave a zero-length left row.
    rightrow:=original||jsonb_build_object('start_time',b);
    changes:=changes||jsonb_build_array(jsonb_build_object('kind','update','before',original,'after',rightrow));
   END IF;
  END IF;
  inserted:=jsonb_build_object('equipment_id',proposed.equipment_id,'status',proposed.status,'start_time',a,'end_time',b,'operator_name',nullif(trim(proposed.operator_name),''),'smu',proposed.smu,'km',proposed.km,'comment',proposed.comment);
  changes:=changes||jsonb_build_array(jsonb_build_object('kind','insert','before',NULL,'after',inserted));
 ELSE
  SELECT * INTO prev FROM public.equipment_events WHERE equipment_id=src.equipment_id AND start_time<src.start_time ORDER BY start_time DESC,id DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND OR prev.end_time IS DISTINCT FROM src.start_time THEN RAISE EXCEPTION 'Өмнөх төлөвтэй яг залгаагүй эсвэл эхний мөр байна. Автоматаар цуцлахгүй'; END IF;
  SELECT * INTO nxt FROM public.equipment_events WHERE equipment_id=src.equipment_id AND start_time>src.start_time ORDER BY start_time,id LIMIT 1 FOR UPDATE;
  IF nxt.id IS NOT NULL AND src.end_time IS DISTINCT FROM nxt.start_time THEN RAISE EXCEPTION 'Дараагийн төлөвтэй залгаагүй. Эхлээд хугацааг шалгана уу'; END IF;
  IF EXISTS(SELECT 1 FROM public.equipment_events e WHERE e.equipment_id=src.equipment_id AND e.id NOT IN(src.id,prev.id) AND (src.end_time IS NULL OR e.start_time<src.end_time) AND (e.end_time IS NULL OR e.end_time>prev.start_time)) THEN RAISE EXCEPTION 'Өөр төлөвтэй давхардалтай. Цуцалсангүй'; END IF;
  -- Never allow a cascading delete or destructive FK side effect.
  IF EXISTS(SELECT 1 FROM pg_constraint WHERE contype='f' AND confrelid='public.equipment_events'::regclass AND confdeltype IN ('c','n','d')) THEN RAISE EXCEPTION 'Хамааралтай хүснэгтийн FK байна. Түүх хамгаалж цуцлахыг хориглов'; END IF;
  changes:=jsonb_build_array(jsonb_build_object('kind','cancel','before',to_jsonb(src),'after',NULL),jsonb_build_object('kind','update','before',to_jsonb(prev),'after',to_jsonb(prev)||jsonb_build_object('end_time',src.end_time)));
 END IF;
 SELECT min(status) INTO new_state FROM public.equipment_events WHERE equipment_id::text=eq AND end_time IS NULL;
 IF p_operation='cancel' AND src.end_time IS NULL THEN new_state:=prev.status; END IF;
 IF p_operation='insert' AND b IS NULL THEN new_state:=proposed.status; END IF;
 plan:=jsonb_build_object('auto_end',auto_end,'next_boundary',next_boundary,'summary_before',eqrow.current_status,'summary_after',new_state,'operation',p_operation,'equipment_id',eq,'equipment_name',eqrow.name,'current_status',eqrow.current_status,'changes',changes,'reason',p_input->>'reason');
 IF p_mode='preview' THEN RETURN jsonb_build_object('ok',true,'plan',plan); END IF;
 IF plan IS DISTINCT FROM p_expected THEN RAISE EXCEPTION 'Шалгаснаас хойш бүртгэл өөрчлөгдсөн. Дахин шалгаж баталгаажуулна уу'; END IF;
 -- Receipt archive is inserted BEFORE any active-row mutation. Failure rolls it back too.
 INSERT INTO public.ets_event_changes_e2(request_id,actor_id,operation,equipment_id,input,plan,result)
 VALUES(p_request,auth.uid(),p_operation,eq,p_input,plan,'{}');
 IF p_operation='cancel' THEN
  DELETE FROM public.equipment_events WHERE id=src.id;
  UPDATE public.equipment_events SET end_time=src.end_time WHERE id=prev.id;
 ELSE
  IF src.id IS NOT NULL THEN
   IF a>src.start_time THEN
    UPDATE public.equipment_events SET end_time=a WHERE id=src.id;
    IF rightrow IS NOT NULL THEN
     SELECT string_agg(quote_ident(attname),',' ORDER BY attnum) INTO cols FROM pg_attribute
      WHERE attrelid='public.equipment_events'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='' AND attidentity='' AND attname NOT IN('id','created_at','updated_at');
     EXECUTE format('INSERT INTO public.equipment_events (%s) SELECT %s FROM jsonb_populate_record(NULL::public.equipment_events,$1)',cols,cols) USING rightrow;
    END IF;
   ELSE UPDATE public.equipment_events SET start_time=b WHERE id=src.id;
   END IF;
  END IF;
  INSERT INTO public.equipment_events(equipment_id,status,start_time,end_time,operator_name,smu,km,comment)
   VALUES(proposed.equipment_id,proposed.status,a,b,nullif(trim(proposed.operator_name),''),proposed.smu,proposed.km,proposed.comment);
 END IF;
 -- Exact final open row is authoritative; closed historical changes never assign an operator.
 SELECT count(*),min(status) INTO n,cols FROM public.equipment_events WHERE equipment_id::text=eq AND end_time IS NULL;
 IF n>1 THEN RAISE EXCEPTION 'Олон нээлттэй төлөв үүсэх тул бүгд буцлаа'; END IF;
 UPDATE public.equipment SET current_status=cols WHERE id=eqrow.id;
 v_result:=jsonb_build_object('ok',true,'request_id',p_request,'equipment_id',eq,'operation',p_operation);
 UPDATE public.ets_event_changes_e2 SET result=v_result WHERE request_id=p_request;
 RETURN v_result;
END$function$;
