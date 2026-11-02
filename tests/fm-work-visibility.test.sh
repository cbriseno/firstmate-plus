#!/usr/bin/env bash
# Explicit project metadata through the genuine owner: defaults, full seeding,
# metadata-only expected values, preserved state, rejected tampering and rollback.
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null || { printf 'SKIP: tasks-axi required\n'; exit 0; }
export FM_LIVE=0
python3 - "$ROOT" <<'PY'
from pathlib import Path
import json,os,subprocess,sys,tempfile,copy
root=Path(sys.argv[1]);checks=0
with tempfile.TemporaryDirectory(prefix='fm-work-visibility-') as tmp:
    home=Path(tmp)
    for part in ('data','state','config'):(home/part).mkdir()
    (home/'data/projects.md').write_text('- alpha [local-only] - Operator\n- public-alpha [local-only install=alpha] - Separate public\n- unclear [local-only] - Unknown\n')
    (home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_'))};env.update(FM_HOME=str(home),FM_LIVE='0',PYTHONDONTWRITEBYTECODE='1')
    def cli(*args,body=None,raw=False):
        p=subprocess.run(['bash',str(root/'bin/fm-tasks-axi.sh'),*args],env=env,text=True,capture_output=True,input=json.dumps(body) if body is not None else None)
        assert p.returncode==0,(args,p.stdout,p.stderr)
        return p.stdout if raw else json.loads(p.stdout)
    def check(value,message):
        global checks
        assert value,message
        checks+=1
    def snap():return cli('work','snapshot')
    def project(key):return next(g for g in snap()['projects'] if g['key']=='project:'+key)
    def structure():return json.loads((home/'data/work-structure.json').read_text())
    action=0
    def op(name,target,**kw):
        global action
        action+=1
        return dict(op=name,target=target,actor='captain',expected_rev=snap()['rev'],request_id='visibility-action-'+str(1000+action),**kw)
    check(project('alpha')['visibility']=='unknown','absence is unknown, not inferred from delivery/name')
    check(project('public-alpha')['visibility']=='public' and project('public-alpha')['installs']=='project:alpha','public install link preserved')
    cli('add','unit','Metadata acceptance','--repo','alpha','--priority','2',raw=True)
    source={'schema':'fm-work-normalization.v1','groups':[{'key':'project:alpha','kind':'project','repo':'alpha','label':'Alpha','visibility':'private'},{'key':'project:public-alpha','kind':'project','repo':'public-alpha','label':'Public alpha','visibility':'public'},{'key':'subproject:alpha/ui','kind':'subproject','repo':'alpha','label':'UI','note':'Keep this note'}],'tasks':[{'id':'unit','subproject':'subproject:alpha/ui','operations':[]}]}
    mp=home/'source.json';ap=home/'additions.json';mp.write_text(json.dumps(source));ap.write_text(json.dumps({'active':['unit'],'groups':[],'membership':{}}))
    seed=cli('work','normalize-plan','--map',str(mp),'--additions',str(ap))
    check(not seed['conflicts'],'full normalizer accepts explicit metadata')
    check(cli('work','normalize-apply','--request-id','visibility-seed-0001',body=seed)['state']=='applied','full owner seeds metadata')
    check(project('alpha')['visibility']=='private','snapshot honors explicit private metadata')
    cli('work','apply',body=op('move','task:unit',before=None,adopt_priority=None))
    cli('hold','unit','--kind','parked','--reason','Keep individual hold',raw=True)
    cli('work','apply',body=op('set_pause','project:alpha',reason='Keep group pause'))
    baseline=structure();backlog=(home/'data/backlog.md').read_bytes()
    check(bool(baseline['groups']['project:alpha']['pause']),'group pause exists before metadata-only upgrade')
    check(baseline['order']==['unit'] and baseline['groups']['subproject:alpha/ui']['note']=='Keep this note','nonempty order and note established through owner')
    metadata=home/'metadata.json'
    def plan(value='unknown',expected=None,key='project:alpha'):
        metadata.write_text(json.dumps({'schema':'fm-work-project-metadata.v1','groups':[{'key':key,'visibility':value,'expected':expected or {'present':True,'value':'private'}}]}))
        return cli('work','normalize-plan','--metadata-only','--map',str(metadata))
    change=plan()
    check(change['operations']==[] and change['kind']=='project-metadata','metadata mode has no task operations')
    wanted=copy.deepcopy(baseline);wanted['groups']['project:alpha']['visibility']='unknown'
    check(change['structure']==wanted,'exact diff changes only declared visibility')
    tampered=copy.deepcopy(change);tampered['structure']['freeze']['except'].append('unexpected')
    check(cli('work','normalize-apply','--request-id','visibility-tamper-0001',body=tampered)['code']=='invalid_value','reject unrelated freeze changes')
    check(structure()==baseline,'tampered plan writes nothing')
    result=cli('work','normalize-apply','--request-id','visibility-upgrade-0001',body=change)
    check(result['state']=='applied' and project('alpha')['visibility']=='unknown','explicit unknown is supported')
    check(structure()==wanted and (home/'data/backlog.md').read_bytes()==backlog,'active/freeze/order/notes/holds unchanged')
    check(project('public-alpha')['visibility']=='public','private metadata never changes public counterpart')
    check(cli('work','normalize-apply','--request-id','visibility-upgrade-0001',body=change)==result,'same migration is idempotent')
    check(cli('work','normalize-rollback','--request-id','visibility-upgrade-0001')['state']=='rolled_back','existing rollback owner works')
    check(structure()==baseline and (home/'data/backlog.md').read_bytes()==backlog,'rollback restores metadata only and keeps hold bytes')
    check(plan(value='secret')['code']=='invalid_value','invalid enum rejected')
    check(plan(value='private',key='subproject:alpha/ui')['code']=='unknown_target','visibility only belongs to project groups')
    stale=plan(expected={'present':False,'value':None})
    check(bool(stale['conflicts']) and structure()==baseline,'stale expected metadata reports conflict without writing')
    change=plan();cli('work','normalize-apply','--request-id','visibility-upgrade-0002',body=change)
    cli('work','apply',body=op('set_priority','project:alpha',value=0))
    check(cli('work','normalize-rollback','--request-id','visibility-upgrade-0002')['code']=='stale_revision','rollback preserves subsequent owner structure changes')
    check(project('alpha')['priority']['own']==0,'later project priority remains')
    poisoned=structure();poisoned['groups']['project:alpha']['visibility']='secret';(home/'data/work-structure.json').write_text(json.dumps(poisoned))
    check(cli('work','snapshot')['code']=='invalid_value','invalid stored metadata fails closed')
    print('PASS: %d explicit visibility owner assertions'%checks)
PY
