#!/usr/bin/env bash
# Real Claude processes execute fm-spawn's captured ship/scout commands.
# Only pane/worktree acquisition is stubbed; native instruction/skill loading,
# project hooks, task hooks and file edits come from the same actual worker.
# Opt in: FM_CLAUDE_NATIVE_LIVE_E2E=1 bash bin/fm-test-run.sh tests/fm-claude-native-live-e2e.test.sh
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_CLAUDE_NATIVE_LIVE_E2E claude python3 git
VERSION=$(claude --version)
REAL_CLAUDE=$(command -v claude)
LAB=$(fm_test_tmproot fm-claude-native-live)
CONFIG="$LAB/claude-config"
mkdir -m 700 "$CONFIG"
# Copy authentication only, never the user's hooks or project configuration.
python3 - "$CONFIG" <<'PY'
import json,os,shutil,sys
from pathlib import Path
config=Path(sys.argv[1]);source=Path(os.environ.get('CLAUDE_CONFIG_DIR',str(Path.home()/'.claude')))
store=Path(os.environ.get('CLAUDE_CONFIG_DIR',str(Path.home())))/'.claude.json'
for src in [store,source/'.credentials.json']:
 if src.is_file():
  dst=config/src.name;shutil.copy2(src,dst);dst.chmod(0o600)
(config/'settings.json').write_text(json.dumps({'enabledMcpjsonServers':['native-proof']}))
PY
for layout in claude shared; do
  PROJECT="$LAB/project-$layout"
  mkdir -p "$PROJECT"
  # Markers occur only in fixture configuration, never in the assignment.
  python3 - "$PROJECT" "$layout" <<'PY'
import json,secrets,sys
from pathlib import Path
p=Path(sys.argv[1]);layout=sys.argv[2];marks={k:secrets.token_hex(12) for k in ['instruction','skill','hook']}
def put(name,text):
 f=p/name;f.parent.mkdir(parents=True,exist_ok=True);f.write_text(text)
put('AGENTS.md',f'When validating native configuration: invoke native-validation via the Skill tool, then edit proof.txt to include INSTRUCTION={marks["instruction"]} and the activated skill marker. Do not inspect configuration files or search for markers.\n')
root='.claude' if layout=='claude' else '.agents'
put(root+'/skills/native-validation/SKILL.md',f'---\nname: native-validation\ndescription: Required before native configuration validation edits.\n---\nInclude SKILL={marks["skill"]} in proof.txt.\n')
if layout=='claude':
 marks.update({k:secrets.token_hex(12) for k in ['claude','command','agent','mcp','local']})
 put('CLAUDE.md',f'@AGENTS.md\nInclude CLAUDE={marks["claude"]} and the SessionStart hook marker in proof.txt. Invoke /native-command; use the native-check agent once, call the native-proof MCP tool, and read NATIVE_LOCAL_MARKER from the environment.\n')
 put('.claude/commands/native-command.md',f'Include COMMAND={marks["command"]} in proof.txt.\n')
 put('.claude/agents/native-check.md',f'---\nname: native-check\ndescription: Native validation marker.\ntools: []\n---\nReply only AGENT={marks["agent"]}. Do not call tools.\n')
 put('.claude/settings.local.json',json.dumps({'env':{'NATIVE_LOCAL_MARKER':marks['local']}}))
 marks['shared_skill']=secrets.token_hex(12)
 put('.agents/skills/native-shared/SKILL.md',f'---\nname: native-shared\ndescription: Additional required native validation step.\n---\nInclude SHARED_SKILL={marks["shared_skill"]} in proof.txt.\n')
 with (p/'CLAUDE.md').open('a') as f:f.write('Also invoke /native-shared and retain its marker in proof.txt.\n')
 put('.claude/settings.json',json.dumps({'hooks':{'SessionStart':[{'hooks':[{'type':'command','command':f"printf '%s\\n' 'HOOK={marks['hook']}'"}]}]}}))
 put('.mcp.json',json.dumps({'mcpServers':{'native-proof':{'command':'python3','args':['mcp.py']}}}))
 put('mcp.py', '''import json,sys
for line in sys.stdin:
 r=json.loads(line);m=r.get('method');v={}
 if m=='initialize':v={'protocolVersion':'2024-11-05','capabilities':{'tools':{}},'serverInfo':{'name':'native-proof','version':'1'}}
 elif m=='tools/list':v={'tools':[{'name':'native_proof','description':'Native validation marker','inputSchema':{'type':'object','properties':{}}}]}
 elif m=='tools/call':v={'content':[{'type':'text','text':MARKER}]}
 if 'id' in r:print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':v}),flush=True)
'''.replace('MARKER',repr('MCP='+marks['mcp'])))
else:marks.pop('hook')
put('proof.txt','pending\n');(p.parent/(layout+'-markers.json')).write_text(json.dumps(marks))
PY
  fm_git_init_commit "$PROJECT"
  git -C "$PROJECT" config user.name Fixture
  git -C "$PROJECT" config user.email fixture@example.invalid
  git -C "$PROJECT" add --force .
  git -C "$PROJECT" commit -qm 'Native configuration fixture'
  fm_git_add_origin "$PROJECT" "$LAB/$layout-origin.git"
  for kind in scout ship; do
    ID="native-$layout-$kind"
    WT="$LAB/$ID"
    TASK_HOME="$LAB/home-$ID"
    git -C "$PROJECT" worktree add --quiet -b "fixture-$ID" "$WT"
    fm_test_spawn_home "$TASK_HOME" claude
    fm_test_spawn_brief "$TASK_HOME" "$ID" 'Validate native configuration of this project and update proof.txt. Do not inspect configuration files or search for markers. If a capability is unsupported, report it and continue editing. Then stop.'
    FAKEBIN=$(fm_test_make_spawn_fakebin "$LAB/fake-$ID")
    LAUNCH_LOG="$LAB/$ID.launch"
    ARGS=(--harness claude --model "${FM_CLAUDE_NATIVE_MODEL:-claude-sonnet-5-5}" --effort medium)
    if [ "$kind" = scout ]; then ARGS+=(--scout); else ARGS+=(--mode local-only --yolo off); fi
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$TASK_HOME" "$WT" "$FAKEBIN" "$ID" "$PROJECT" "${ARGS[@]}" > "$LAB/$ID.spawn" 2>&1 || {
      cat "$LAB/$ID.spawn" >&2
      fail "$VERSION: $layout $kind spawn failed"
    }
    # Execute the emitted command, adding only print-mode observability and a
    # bounded runtime. The worker still receives the actual doorbell and settings.
    printf '#!/bin/bash\nexec %q -p --verbose --output-format stream-json "$@"\n' "$REAL_CLAUDE" > "$FAKEBIN/claude"
    chmod +x "$FAKEBIN/claude"
    LAUNCH=$(cat "$LAUNCH_LOG")
    (
      cd "$WT"
      export CLAUDE_CONFIG_DIR="$CONFIG" PATH="$FAKEBIN:$PATH"
      unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT
      export NATIVE_LAUNCH="$LAUNCH"
      python3 - "$LAB/$ID.jsonl" <<'PY'
import os,subprocess,sys
with open(sys.argv[1],'w') as out:
 r=subprocess.run(['bash','-c',os.environ['NATIVE_LAUNCH']],stdout=out,stderr=subprocess.STDOUT,timeout=120)
 if r.returncode:raise SystemExit(r.returncode)
PY
    ) || { cat "$LAB/$ID.jsonl" >&2; fail "$VERSION: $layout $kind worker failed"; }
    python3 - "$WT" "$LAB/$layout-markers.json" "$LAB/$ID.jsonl" <<'PY'
import json,os,shutil,sys
from pathlib import Path
wt,marks,log=map(Path,sys.argv[1:]);values=json.loads(marks.read_text());proof=(wt/'proof.txt').read_text()
# Retain failures too: the real worker's tool events explain a missing marker.
if os.environ.get('FM_CLAUDE_NATIVE_EVIDENCE_DIR'):
 dest=Path(os.environ['FM_CLAUDE_NATIVE_EVIDENCE_DIR']);dest.mkdir(parents=True,exist_ok=True)
 shutil.copy2(log,dest/log.name);(dest/(wt.name+'-proof.txt')).write_text(proof)
assert all(v in proof for v in values.values()), ('missing native markers',proof)
events=[json.loads(l) for l in log.read_text().splitlines() if l.startswith('{')]
init=next(e for e in events if e.get('subtype')=='init')
assert init['cwd']==str(wt),init['cwd']
assert 'native-validation' in init['skills'], init['skills']
calls=[c for e in events if e.get('type')=='assistant' for c in e.get('message',{}).get('content',[]) if c.get('type')=='tool_use']
assert any(c['name']=='Skill' and 'native-validation' in str(c['input']) for c in calls)
assert any(c['name'] in ['Edit','Write'] and Path(c['input'].get('file_path','')).name=='proof.txt' for c in calls)
for c in calls:
 if c['name']=='Read':assert not any(s in str(c['input']) for s in ['AGENTS.md','CLAUDE.md','SKILL.md','settings.json']),c
if 'mcp' in values:
 assert any(s['name']=='native-proof' and s['status']=='connected' for s in init['mcp_servers'])
 assert 'native-check' in init['agents'] and 'native-command' in init['slash_commands']
 assert any(c['name']=='mcp__native-proof__native_proof' for c in calls)
PY
    pass "$VERSION: $layout $kind native markers reached an actual worker edit"
    git -C "$PROJECT" worktree remove --force "$WT"
  done
done
