#!/usr/bin/env node
// Semantic policy for the primary write guard: does this tool call make the
// PRIMARY firstmate session write outside its private operational paths?
//
// config/primary-direct-ops selects simple host operations or delegation-only
// writes. The transport owns scope and allowed paths; this policy owns target
// resolution and the safety decisions. See docs/primary-write-guard.md.
//
// Shell lexing is imported from bin/fm-arm-command-policy.mjs, the sole owner
// of firstmate's shell classification. This policy never evaluates, expands,
// sources, or runs any byte of the submitted command; it reads lexical command
// positions, redirection targets, and literal inline-code paths only. Its
// The threat model is agent mistakes, not deliberate obfuscation. Host mode
// refuses unresolved writes; off retains the legacy literal-prefix policy.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import path from "node:path";
import { execFileSync, spawnSync } from "node:child_process";
import { realpathSync, appendFileSync, statSync, lstatSync } from "node:fs";
import { fileURLToPath } from "node:url";

const FILE_TOOLS = new Set(["Edit", "MultiEdit", "Write", "NotebookEdit"]);
const SHELL_TOOLS = new Set(["Bash"]);
const PATCH_TOOLS = new Set(["apply_patch"]);

const DEVICE_FILES = new Set(["/dev/null", "/dev/stdout", "/dev/stderr", "/dev/tty"]);
const DEVICE_PREFIXES = ["/dev/fd/", "/proc/self/fd/"];

const INPUT_REDIRECTIONS = new Set(["<", "<<", "<<-", "<<<", "<&"]);
const SHELLS = new Set(["bash", "sh", "zsh", "dash", "ksh"]);
const INTERPRETERS = new Set(["python", "python2", "python3", "node", "nodejs", "bun", "deno", "perl", "ruby"]);
const MAX_DEPTH = 4;

// Git subcommands that change a repository's working tree, index, or history.
// HOME_CHECKOUT_GIT is the one sanctioned firstmate-initiated git write on the
// home's own checkout: restoring the primary branch after a worktree tangle.
const MUTATING_GIT = new Set([
  "add", "am", "apply", "checkout", "cherry-pick", "clean", "clone", "commit", "init", "merge",
  "mv", "pull", "rebase", "reset", "restore", "revert", "rm", "stash", "switch",
]);
const HOME_CHECKOUT_GIT = new Set(["checkout", "switch"]);

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

// ---------------------------------------------------------------------------
// Target resolution.
// ---------------------------------------------------------------------------

// Expand a leading tilde and $NAME / ${NAME} references that the hook's own
// environment defines. Stop at the first reference it cannot resolve, a glob,
// or a brace expansion: everything before it is the literal prefix, and the
// returned `partial` flag says the real target extends it unpredictably.
function expandTarget(raw, env) {
  let value = raw;
  if (value === "~" || value.startsWith("~/")) value = (env.HOME || "~") + value.slice(1);
  let out = "";
  for (let i = 0; i < value.length; i += 1) {
    const char = value[i];
    if (char === "$") {
      const braced = value.slice(i).match(/^\$\{([A-Za-z_][A-Za-z0-9_]*)\}/);
      const bare = value.slice(i).match(/^\$([A-Za-z_][A-Za-z0-9_]*)/);
      const match = braced || bare;
      if (match && typeof env[match[1]] === "string" && env[match[1]] !== "") {
        out += env[match[1]];
        i += match[0].length - 1;
        continue;
      }
      return { value: out, partial: true };
    }
    if ("*?[".includes(char)) return { value: out, partial: true };
    if (char === "{" && /^\{[^}]*,[^}]*\}/.test(value.slice(i))) return { value: out, partial: true };
    out += char;
  }
  return { value: out, partial: false };
}

// Canonicalize through the deepest existing ancestor so a symlinked temp dir or
// home resolves the same way as the allowed roots it is compared against.
function canonical(target) {
  let existing = target;
  const rest = [];
  while (existing !== path.dirname(existing)) {
    try {
      const real = realpathSync(existing);
      return rest.length ? path.join(real, ...rest.reverse()) : real;
    } catch {
      rest.push(path.basename(existing));
      existing = path.dirname(existing);
    }
  }
  return target;
}

function within(target, root) {
  return target === root || target.startsWith(root.endsWith("/") ? root : `${root}/`);
}

// ---------------------------------------------------------------------------
// The judgement over one candidate target.
// ---------------------------------------------------------------------------

class Judge {
  constructor(options) {
    this.env = options.env;
    this.host = options.hostMode === "host";
    this.userHome = canonical(path.resolve(options.env.HOME || "/nonexistent"));
    this.projectRoots = (options.projectRoots || []).map((root) => canonical(path.resolve(root)));
    this.log = options.auditLog;
    this.staleIndexLock = options.staleIndexLock;
    this.tool = options.tool;
    this.systemRoot = path.resolve(options.systemRoot || "/");
    this.writes = new Set();
    this.commandClass = FILE_TOOLS.has(options.tool) ? "file-edit" : "write";
    this.allowRoots = options.allow.map((root) => canonical(path.resolve(root)));
    this.allowFiles = options.allowFiles.map((file) => canonical(path.resolve(file)));
    this.protect = options.protect.map((root) => canonical(path.resolve(root)));
    this.grants = options.grants.map((root) => canonical(path.resolve(root)));
    // Name prefixes such as "<home>/scratchpad": the directory part is
    // canonicalized, the trailing name stem is kept as typed.
    this.allowPrefixes = options.allowPrefixes.map((prefix) => path.join(canonical(path.dirname(path.resolve(prefix))), path.basename(prefix)));
    this.projects = options.projects ? canonical(path.resolve(options.projects)) : "";
    this.homeCheckouts = [...new Set(options.homeCheckouts.map((root) => canonical(path.resolve(root))))];
    this.trackedFiles = [];
    if (this.host) {
      for (const root of this.homeCheckouts) {
        try {
          const names = execFileSync("git", ["-C", root, "ls-files", "-z"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
          this.trackedFiles.push(...names.split("\0").filter(Boolean).map((name) => canonical(path.join(root, name))));
        } catch { /* A non-repository operational home has no tracked files. */ }
      }
    }
  }

  isProject(target) {
    return (this.projects && within(target, this.projects)) || this.projectRoots.some((root) => within(target, root));
  }

  secret(raw, cwd) {
    const expanded = expandTarget(raw, this.env);
    const target = canonical(path.resolve(cwd || this.userHome, expanded.value));
    if (/(?:^|\/)(?:\.ssh|\.gnupg)(?:\/|$)|(?:^|\/)(?:\.env(?:\.[^/]*)?|credentials(?:\.[^/]*)?|id_(?:rsa|ed25519|ecdsa)|[^/]*\.(?:pem|key))$/.test(target)) {
      return { code: "primary-secret", target };
    }
    return null;
  }

  audit() {
    if (!this.host || !this.log) return;
    for (const entry of this.writes) {
      try { appendFileSync(this.log, `${new Date().toISOString()}\t${this.tool}\t${entry}\n`); } catch { /* best effort */ }
    }
  }

  allowedPath(target) {
    if (this.allowFiles.includes(target)) return true;
    if (this.allowPrefixes.some((prefix) => target.startsWith(prefix) && !target.slice(prefix.length).includes("/../"))) return true;
    return this.allowRoots.some((root) => within(target, root));
  }

  // Could some completion of literal prefix `prefix` still land in an allowed
  // path? A prefix such as "/tm" or "/srv/me/fm/st" can, "/srv/me/.config/"
  // cannot.
  prefixCanBeAllowed(prefix) {
    const candidates = [...this.allowRoots, ...this.allowFiles, ...this.allowPrefixes, ...this.grants, ...DEVICE_FILES, ...DEVICE_PREFIXES];
    return candidates.some((root) => root.startsWith(prefix) || within(prefix, root));
  }

  systemDenied(target, treeWrite = false) {
    const root = this.systemRoot;
    const at = (name) => path.join(root, name);
    const exceptions = ["usr/local", "private/tmp", "private/var/folders"].map(at);
    if (exceptions.some((entry) => within(target, entry) || within(target, canonical(entry)))) return false;
    return ["etc", "bin", "sbin", "boot", "dev", "proc", "sys", "usr", "var/lib", "var/db", "lib", "lib64", "System", "Library", "private/etc", "private/var", "Applications/Utilities"]
      .map(at).some((entry) => within(target, entry) || within(target, canonical(entry)) || (treeWrite && (within(entry, target) || within(canonical(entry), target))));
  }

  // Returns null to allow, or a deny {code, target}.
  check(raw, cwd, { gitHome = false, recursive = false, treeWrite = false } = {}) {
    const expanded = expandTarget(raw, this.env);
    let value = expanded.value;
    if (this.host && recursive && (expanded.partial || !value)) return { code: "primary-delete", target: raw };
    if (!value) return this.host ? { code: "primary-write", target: raw } : null;
    if (!path.isAbsolute(value)) {
      if (!cwd) return this.host ? { code: "primary-write", target: raw } : null;
      value = path.join(cwd, value);
    }
    if (expanded.partial) {
      if (this.host) return { code: "primary-write", target: raw };
      // Keep the trailing slash or partial component: "/srv/me/.con" must stay
      // a prefix of "/srv/me/.config", not collapse to "/home/me".
      const prefix = path.resolve(value) + (value.endsWith("/") ? "/" : "");
      if (this.prefixCanBeAllowed(prefix) || this.prefixCanBeAllowed(canonical(path.resolve(value)))) return null;
      return this.denial(path.resolve(value), raw);
    }
    const resolved = path.resolve(value);
    if (DEVICE_FILES.has(resolved) || DEVICE_PREFIXES.some((prefix) => resolved.startsWith(prefix))) return null;
    const target = canonical(resolved);
    if (this.host && recursive && (target === this.userHome || target === "/" || path.dirname(resolved) === "/" || path.dirname(target) === "/" || ["/etc", "/var", "/bin", "/sbin", "/tmp"].some((root) => target === canonical(root)))) return { code: "primary-delete", target };
    if (this.protect.some((root) => within(target, root))) return { code: "primary-write-grant-record", target };
    // A live captain-approval grant is the only way into a project clone; it
    // outranks every other allowance, so a temp-dir or home-root allowance can
    // never reach a project by accident.
    if (!gitHome && this.trackedFiles.some((file) => within(target, file) || ((recursive || treeWrite) && within(file, target)))) return this.denial(target, raw);
    if (this.host && this.env.FM_ALLOW_PRIMARY_WRITE !== "1" && (this.systemDenied(resolved, recursive || treeWrite) || this.systemDenied(target, recursive || treeWrite))) return this.denial(target, raw);
    if (this.grants.some((root) => within(target, root))) {
      this.writes.add(`${target.replace(/[\t\r\n]/g, " ")}\t${this.commandClass}`);
      return null;
    }
    if (this.host && (recursive || treeWrite) && ((this.projects && within(this.projects, target)) || this.projectRoots.some((root) => within(root, target)))) return { code: "primary-write-project", target };
    if (this.isProject(target)) return this.denial(target, raw);
    if (this.allowedPath(target)) {
      this.writes.add(`${target.replace(/[\t\r\n]/g, " ")}\t${this.commandClass}`);
      return null;
    }
    if (!gitHome && this.homeCheckouts.includes(target)) return this.denial(target, raw);
    if (gitHome && this.homeCheckouts.some((root) => within(target, root)) && !(this.projects && within(target, this.projects))) return null;
    if (this.host && !this.homeCheckouts.some((root) => within(target, root))) {
      this.writes.add(`${target.replace(/[\t\r\n]/g, " ")}\t${recursive ? "recursive-delete" : this.commandClass}`);
      return null;
    }
    return this.denial(target, raw);
  }

  denial(target, raw) {
    if (this.isProject(target)) return { code: "primary-write-project", target, raw };
    return { code: "primary-write", target, raw };
  }
}

// ---------------------------------------------------------------------------
// Shell command analysis.
// ---------------------------------------------------------------------------

function operands(words) {
  const result = [];
  let endOfOptions = false;
  for (const word of words) {
    if (!endOfOptions && word.value === "--") {
      endOfOptions = true;
      continue;
    }
    if (!endOfOptions && word.value.startsWith("-") && word.value !== "-") continue;
    result.push(word);
  }
  return result;
}

// Skip options that take a separate argument so the argument is not mistaken
// for an operand. `takes` lists short letters and long names with arguments.
function operandsSkipping(words, takes) {
  const result = [];
  let endOfOptions = false;
  for (let i = 0; i < words.length; i += 1) {
    const value = words[i].value;
    if (!endOfOptions && value === "--") {
      endOfOptions = true;
      continue;
    }
    if (!endOfOptions && value.startsWith("--")) {
      if (!value.includes("=") && takes.has(value.slice(2))) i += 1;
      continue;
    }
    if (!endOfOptions && value.startsWith("-") && value !== "-") {
      if (takes.has(value.slice(1).at(-1))) i += 1;
      continue;
    }
    result.push(words[i]);
  }
  return result;
}

// The value of a short option, including inside a cluster (`-fsSLo out`,
// `-qO-`, `-ofile`), or of a long option given as `--name value` or
// `--name=value`.
function optionValue(words, shortName, longName) {
  for (let i = 0; i < words.length; i += 1) {
    const value = words[i].value;
    if (shortName && /^-[A-Za-z]/.test(value)) {
      const at = value.indexOf(shortName, 1);
      if (at !== -1 && /^[A-Za-z]*$/.test(value.slice(1, at))) {
        if (at === value.length - 1) {
          if (words[i + 1]) return words[i + 1];
        } else {
          return { ...words[i], value: value.slice(at + 1) };
        }
      }
    }
    if (longName && value === `--${longName}` && words[i + 1]) return words[i + 1];
    if (longName && value.startsWith(`--${longName}=`)) return { ...words[i], value: value.slice(longName.length + 3) };
  }
  return null;
}

// String literal: '...' or "..." without embedded quotes of the same kind.
const LIT = String.raw`(?:'([^'\n]*)'|"([^"\n]*)")`;

function literalAt(match, index) {
  return match[index] !== undefined ? match[index] : match[index + 1];
}

// Rewrite home-relative constructs to a "~/..." literal so the path patterns
// below see them: os.path.expanduser('~/x'), Path('~/x').expanduser(),
// Path.home() / 'x', and path.join(os.homedir(), 'x').
function normalizeInlineCode(code) {
  return code
    .replace(new RegExp(String.raw`os\.path\.expanduser\(\s*${LIT}\s*\)`, "g"), (_m, a, b) => `'${a ?? b}'`)
    .replace(new RegExp(String.raw`Path\(\s*${LIT}\s*\)\s*\.\s*expanduser\(\s*\)`, "g"), (_m, a, b) => `Path('${a ?? b}')`)
    .replace(new RegExp(String.raw`Path\.home\(\s*\)\s*/\s*${LIT}`, "g"), (_m, a, b) => `Path('~/${a ?? b}')`)
    .replace(new RegExp(String.raw`(?<![\w.])\(\s*(Path\(\s*${LIT}\s*\))\s*\)`, "g"), "$1")
    .replace(new RegExp(String.raw`(?:require\(\s*['"](?:node:)?path['"]\s*\)|path)\.join\(\s*(?:require\(\s*['"](?:node:)?os['"]\s*\)|os)\.homedir\(\s*\)\s*,\s*${LIT}\s*\)`, "g"), (_m, a, b) => `'~/${a ?? b}'`)
    .replace(new RegExp(String.raw`\bopen\(\s*Path\(\s*${LIT}\s*\)`, "g"), (_m, a, b) => `open('${a ?? b}'`);
}

// Literal write targets in inline interpreter code. Only common literal-path
// write calls are recognized; computed paths are a documented residual.
function inlineCodeTargets(code) {
  const source = normalizeInlineCode(code);
  const targets = [];
  const patterns = [
    // Python open(path, mode) with a writing mode.
    { re: new RegExp(String.raw`\bopen\(\s*${LIT}\s*,\s*(?:mode\s*=\s*)?${LIT}`, "g"), pick: (m) => (/[wax+]/.test(literalAt(m, 3)) ? [literalAt(m, 1)] : []) },
    // Python pathlib writes.
    { re: new RegExp(String.raw`\bPath\(\s*${LIT}\s*\)\s*\.\s*(?:write_text|write_bytes|touch|mkdir|unlink|rmdir|rename|replace|symlink_to|chmod)\b`, "g"), pick: (m) => [literalAt(m, 1)] },
    // Python os / shutil single-target writes.
    { re: new RegExp(String.raw`\b(?:os\.(?:remove|unlink|rmdir|removedirs|makedirs|mkdir|chmod|truncate)|shutil\.rmtree)\(\s*${LIT}`, "g"), pick: (m) => [literalAt(m, 1)] },
    // Python two-path writes: the destination, and both sides of a move.
    { re: new RegExp(String.raw`\b(shutil\.(?:copy|copy2|copyfile|copytree|move)|os\.(?:rename|replace|symlink|link))\(\s*${LIT}\s*,\s*${LIT}`, "g"), pick: (m) => (/move|rename|replace/.test(m[1]) ? [literalAt(m, 2), literalAt(m, 4)] : [literalAt(m, 4)]) },
    // Node fs single-target writes.
    { re: new RegExp(String.raw`\b(?:writeFileSync|appendFileSync|writeFile|appendFile|mkdirSync|rmSync|rmdirSync|unlinkSync|truncateSync|createWriteStream|chmodSync|fs\.promises\.(?:writeFile|appendFile|mkdir|rm|unlink)|fs\.(?:mkdir|rm|rmdir|unlink|truncate|chmod))\(\s*${LIT}`, "g"), pick: (m) => [literalAt(m, 1)] },
    // Node fs two-path writes.
    { re: new RegExp(String.raw`\b(copyFileSync|copyFile|cpSync|renameSync|rename|symlinkSync|linkSync)\(\s*${LIT}\s*,\s*${LIT}`, "g"), pick: (m) => (/rename/.test(m[1]) ? [literalAt(m, 2), literalAt(m, 4)] : [literalAt(m, 4)]) },
    // Ruby File.write / File.open(path, "w"), FileUtils single-target writes.
    { re: new RegExp(String.raw`\bFile\.(?:write|binwrite)\(\s*${LIT}`, "g"), pick: (m) => [literalAt(m, 1)] },
    { re: new RegExp(String.raw`\bFile\.open\(\s*${LIT}\s*,\s*${LIT}`, "g"), pick: (m) => (/[wa+]/.test(literalAt(m, 3)) ? [literalAt(m, 1)] : []) },
    { re: new RegExp(String.raw`\bFileUtils\.(?:rm|rm_r|rm_rf|rm_f|mkdir|mkdir_p|touch)\(\s*${LIT}`, "g"), pick: (m) => [literalAt(m, 1)] },
    // Perl three-argument and two-argument open for writing.
    { re: new RegExp(String.raw`\bopen\s*\(?\s*[^,()]+,\s*['"](?:>|>>|\+<|\+>)['"]\s*,\s*${LIT}`, "g"), pick: (m) => [literalAt(m, 1)] },
    { re: /\bopen\s*\(?\s*[^,()]+,\s*['"](?:>>?|\+[<>])\s*([^'"]+)['"]/g, pick: (m) => [m[1]] },
  ];
  for (const { re, pick } of patterns) {
    for (const match of source.matchAll(re)) {
      for (const target of pick(match)) if (target) targets.push(target);
    }
  }
  return targets;
}

// Paths named by an apply_patch envelope (Codex's file-edit tool).
function patchTargets(patch) {
  const targets = [];
  for (const line of patch.split("\n")) {
    const match = line.match(/^\*\*\* (?:Add File|Update File|Delete File|Move to): (.+?)\s*$/);
    if (match) targets.push(match[1]);
  }
  return targets;
}

// find -exec and xargs substitute `{}` (or a chosen replace string spelled
// `{}`) at run time, so such a word keeps its operand position but is never
// judged as a literal path.
function placeholders(words) {
  return words.map((word) => (word.value.includes("{}") ? { ...word, subs: [...word.subs, { kind: "placeholder", content: "" }] } : word));
}

class ShellAnalyzer {
  constructor(judge) {
    this.judge = judge;
  }

  // Returns the first denial in the program, or null.
  program(command, cwd, depth = 0) {
    if (depth > MAX_DEPTH) return null;
    const lexed = new Lexer(command).tokenize();
    // Fail open on syntax the classifier cannot tokenize, like the cd-guard:
    // an ordinary agent write always tokenizes, and a false block on a
    // firstmate-owned record write is worse than a missed exotic shape.
    if (lexed.error) return null;
    const { nodes } = splitProgram(lexed.tokens);
    let current = cwd;
    const previousEnv = this.judge.env;
    if (this.judge.host) {
      this.judge.env = { ...previousEnv };
      if (depth === 0) {
        for (const key of Object.keys(this.judge.env)) {
          if (!["HOME", "FM_HOME", "FM_ALLOW_PRIMARY_WRITE"].includes(key)) delete this.judge.env[key];
        }
      }
    }
    try {
      for (const node of nodes) {
        const result = this.node(node, current, depth);
        if (result.denial) return result.denial;
        current = result.cwd;
        if (this.judge.host && !lexed.tokens.some((token) => token.type === "op" && ["&&", "||", "|", "&"].includes(token.value))) this.assignments(node);
      }
      return null;
    } finally { this.judge.env = previousEnv; }
  }

  assignments(tokens) {
    const words = tokens.filter((token) => token.type === "word");
    const offset = words[0]?.value === "export" ? 1 : 0;
    if (words[0]?.value === "for" && words[1]) {
      delete this.judge.env[words[1].value];
      return;
    }
    if (words[0]?.value === "read" || words[0]?.value === "unset") {
      for (const word of words.slice(1)) delete this.judge.env[word.value];
      return;
    }
    if (!words.length || tokens.length !== words.length || !words.slice(offset).every((word) => /^[A-Za-z_][A-Za-z0-9_]*=/.test(word.value))) return;
    for (const word of words.slice(offset)) {
      const match = word.value.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s);
      if (!match || match[1] === "FM_ALLOW_PRIMARY_WRITE") continue;
      const value = expandTarget(match[2], this.judge.env);
      if (word.subs.length || value.partial || (word.quoted && (match[2].includes("$") || match[2].startsWith("~"))) || !path.isAbsolute(value.value)) delete this.judge.env[match[1]];
      else this.judge.env[match[1]] = value.value;
    }
  }

  node(rawTokens, cwd, depth) {
    // The shared lexer reads a bare `{}` (find -exec, xargs -I{}) as an empty
    // brace group; bash treats it as an ordinary word, so restore it as one.
    const bodyTokens = rawTokens[0]?.value === "do" ? rawTokens.slice(1) : rawTokens;
    const tokens = bodyTokens.map((token) => (token.type === "group" && token.kind === "brace" && !token.content.trim()
      ? { type: "word", value: "{}", literal: true, subs: [], quoted: false, unquotedExpansion: true }
      : token));
    const initialCommand = commandPosition(tokens).command;
    this.judge.commandClass = basename(initialCommand?.value || "write").replace(/[^A-Za-z0-9_.-]/g, "_");
    const check = (raw, options) => this.judge.check(raw, cwd, options);
    // Redirection targets.
    for (let i = 0; i < tokens.length; i += 1) {
      const token = tokens[i];
      if (token.type !== "redir" || token.inlineTarget || INPUT_REDIRECTIONS.has(token.value)) continue;
      const target = tokens[i + 1];
      if (!target || target.type !== "word") continue;
      if (target.subs.length) {
        if (this.judge.host) return { denial: { code: "primary-write", target: "unresolved output target" }, cwd };
        continue;
      }
      const denial = check(target.value);
      if (denial) return { denial, cwd };
    }
    // Nested programs: groups, command and process substitutions.
    for (const token of tokens) {
      if (token.type === "group") {
        const denial = this.program(token.content, cwd, depth + 1);
        if (denial) return { denial, cwd };
      }
      if (token.type === "word") {
        for (const sub of token.subs) {
          const denial = this.program(sub.content, cwd, depth + 1);
          if (denial) return { denial, cwd };
        }
      }
    }
    const position = commandPosition(tokens);
    if (this.judge.host && (position.wrappers.includes("sudo") || ["sudo", "doas", "su", "pkexec"].includes(basename(position.command?.value || "")))) {
      return { denial: { code: "primary-privilege", target: "privilege escalation" }, cwd };
    }
    for (const payload of position.wrapperPayloads) {
      const denial = this.program(payload, cwd, depth + 1);
      if (denial) return { denial, cwd };
    }
    if (!position.command) return { denial: null, cwd };
    const name = basename(position.command.value);
    const args = position.words.slice(position.index + 1);
    if (name === "cd" || name === "pushd") return { denial: null, cwd: this.changeDirectory(args, cwd) };
    const heredocs = tokens.filter((token) => token.type === "redir" && typeof token.heredoc === "string").map((token) => token.heredoc);
    const hereStrings = [];
    for (let i = 0; i < tokens.length; i += 1) {
      if (tokens[i].type === "redir" && tokens[i].value === "<<<" && tokens[i + 1]?.type === "word") hereStrings.push(tokens[i + 1].value);
    }
    const denial = this.command(name, args, cwd, depth, [...heredocs, ...hereStrings]);
    return { denial, cwd };
  }

  changeDirectory(args, cwd) {
    const target = operands(args)[0];
    if (!target) return this.judge.env.HOME || null;
    const expanded = expandTarget(target.value, this.judge.env);
    if (expanded.partial || target.subs.length) return null;
    if (path.isAbsolute(expanded.value)) return path.resolve(expanded.value);
    return cwd ? path.resolve(cwd, expanded.value) : null;
  }

  checkAll(words, cwd, options) {
    for (const word of words) {
      if (word.subs.length || (this.judge.host && word.literal && word.value.includes("$"))) {
        if (this.judge.host) return { code: "primary-write", target: "unresolved target" };
        continue;
      }
      const denial = this.judge.check(word.value, cwd, options);
      if (denial) return denial;
    }
    return null;
  }

  destination(destination, sources, cwd) {
    if (!destination) return null;
    if (!this.judge.host) return this.checkAll([destination], cwd);
    const expanded = expandTarget(destination.value, this.judge.env);
    if (expanded.partial || destination.subs.length || !cwd) return this.checkAll([destination], cwd);
    const target = path.resolve(cwd, expanded.value);
    try { if (!statSync(target).isDirectory()) return this.checkAll([destination], cwd); }
    catch { return this.checkAll([destination], cwd); }
    for (const source of sources) {
      const value = expandTarget(source.value, this.judge.env);
      if (value.partial || source.subs.length) return { code: "primary-write", target: "unresolved copy destination" };
      // Copying . or a directory's contents can affect any child of target.
      if (/^(?:\.|\.\.)$|\/\.$/.test(value.value)) return this.judge.check(target, cwd, { treeWrite: true });
      const denial = this.judge.check(path.join(target, path.basename(value.value)), cwd, { treeWrite: true });
      if (denial) return denial;
    }
    return null;
  }

  command(name, args, cwd, depth, stdinPayloads) {
    if (this.judge.host && ["cat", "head", "tail", "less", "more", "sed", "awk", "grep", "rg", "bat", "base64", "strings"].includes(name)) {
      for (const word of operands(args)) {
        const secret = this.judge.secret(word.value, cwd);
        if (secret) return secret;
      }
    }
    switch (name) {
      case "tee":
        return this.checkAll(operandsSkipping(args, new Set(["output-error"])), cwd);
      case "cp":
      case "install":
      case "ln":
      case "rsync": {
        const targetDir = optionValue(args, "t", "target-directory");
        if (targetDir) {
          const sources = operandsSkipping(args, new Set(["t", "target-directory", "m", "o", "g", "mode", "owner", "group"]));
          return this.destination(targetDir, sources, cwd);
        }
        const list = operandsSkipping(args, new Set(["m", "o", "g", "S", "mode", "owner", "group", "suffix"]));
        if (name === "install" && args.some((word) => word.value === "-d" || word.value === "--directory")) return this.checkAll(list, cwd);
        if (list.length < 2) return null;
        const destination = list.at(-1);
        if (name === "rsync" && /^[^/]*:/.test(destination.value)) return null;
        if (name === "rsync" || args.some((word) => word.value === "--parents")) return this.checkAll([destination], cwd, { treeWrite: true });
        return this.destination(destination, list.slice(0, -1), cwd);
      }
      case "mv": {
        const targetDir = optionValue(args, "t", "target-directory");
        const list = operandsSkipping(args, new Set(["S", "suffix", "t", "target-directory"]));
        const denial = this.checkAll(targetDir ? list : list.slice(0, -1), cwd, { treeWrite: true });
        if (denial) return denial;
        return this.destination(targetDir || list.at(-1), targetDir ? list : list.slice(0, -1), cwd);
      }
      case "rm": {
        // Only this exact single-file deletion may recover an orphaned home index.
        const lock = this.judge.staleIndexLock;
        if (lock && args.length === 2 && args[0].value === "--" && args[1].value === lock && !args[1].subs.length) {
          try {
            const info = lstatSync(lock);
            if (realpathSync(lock) === lock && info.isFile() && info.size === 0 && Date.now() - info.mtimeMs > 600000) {
              const git = spawnSync("pgrep", ["-x", "git"], { stdio: "ignore" });
              if (git.status === 1 && !git.error) {
                this.judge.writes.add(`${lock.replace(/[\t\r\n]/g, " ")}\trm`);
                return null;
              }
            }
          } catch { /* Missing or unreadable locks retain the ordinary refusal. */ }
        }
        const recursive = args.some((word) => /^-[^-]*[rR]/.test(word.value) || word.value === "--recursive");
        if (this.judge.host && recursive && (!operands(args).length || operands(args).some((word) => word.subs.length))) return { code: "primary-delete", target: "unresolved recursive delete" };
        return this.checkAll(operands(args), cwd, { recursive });
      }
      case "rmdir":
      case "unlink":
      case "shred":
        return this.checkAll(operands(args), cwd);
      case "touch":
        return this.checkAll(operandsSkipping(args, new Set(["d", "r", "t", "reference", "date"])), cwd);
      case "mkdir":
        return this.checkAll(operandsSkipping(args, new Set(["m", "mode", "context"])), cwd);
      case "truncate":
        return this.checkAll(operandsSkipping(args, new Set(["s", "r", "size", "reference"])), cwd);
      case "chmod":
      case "chown":
      case "chgrp": {
        const list = operandsSkipping(args, new Set(["reference"]));
        const hasReference = args.some((word) => word.value.startsWith("--reference"));
        return this.checkAll(hasReference ? list : list.slice(1), cwd);
      }
      case "sed":
        return this.sed(args, cwd);
      case "dd": {
        const output = args.find((word) => word.value.startsWith("of="));
        return output ? this.checkAll([{ ...output, value: output.value.slice(3) }], cwd) : null;
      }
      case "curl": {
        const output = optionValue(args, "o", "output");
        if (output) return this.checkAll([output], cwd);
        const outputDir = optionValue(args, null, "output-dir");
        if (args.some((word) => word.value === "-O" || word.value === "--remote-name" || word.value === "--remote-name-all")) {
          return outputDir ? this.checkAll([outputDir], cwd) : this.cwdTarget(cwd);
        }
        return null;
      }
      case "wget": {
        const output = optionValue(args, "O", "output-document");
        if (output) return output.value === "-" ? null : this.checkAll([output], cwd);
        const prefix = optionValue(args, "P", "directory-prefix");
        return prefix ? this.checkAll([prefix], cwd) : this.cwdTarget(cwd);
      }
      case "git":
        return this.git(args, cwd);
      case "apply_patch":
        for (const payload of stdinPayloads) {
          const denial = this.checkAll(patchTargets(payload).map((value) => ({ value, subs: [] })), cwd);
          if (denial) return denial;
        }
        return null;
      case "eval":
        return this.program(args.map((word) => word.value).join(" "), cwd, depth + 1);
      case "xargs":
        return this.xargs(args, cwd, depth);
      case "find":
        return this.find(args, cwd, depth);
      default:
        break;
    }
    if (SHELLS.has(name)) return this.shell(args, cwd, depth, stdinPayloads);
    if (INTERPRETERS.has(name) || /^python[0-9.]+$/.test(name)) return this.interpreter(name, args, cwd, stdinPayloads);
    return null;
  }

  cwdTarget(cwd) {
    return cwd ? this.judge.check(cwd, cwd) : null;
  }

  // GNU and BSD sed: `-i[SUFFIX]` consumes the rest of its cluster, so `-ie`
  // is in-place with suffix "e" and the script stays the first operand, while
  // `-e SCRIPT` / `-f FILE` (alone or ending a cluster without `i`) supply the
  // script and leave every operand a file.
  sed(args, cwd) {
    const inPlace = args.some((word) => /^-[a-zA-Z]*i/.test(word.value) || word.value.startsWith("--in-place"));
    if (!inPlace) return null;
    const files = [];
    let scriptFromOption = false;
    let endOfOptions = false;
    for (let i = 0; i < args.length; i += 1) {
      const value = args[i].value;
      if (!endOfOptions && value === "--") {
        endOfOptions = true;
        continue;
      }
      if (!endOfOptions && value === "-i" && args[i + 1]?.value === "") {
        i += 1;
        continue;
      }
      if (!endOfOptions && /^--(?:expression|file)$/.test(value)) {
        scriptFromOption = true;
        i += 1;
        continue;
      }
      if (!endOfOptions && /^--(?:expression|file)=/.test(value)) {
        scriptFromOption = true;
        continue;
      }
      if (!endOfOptions && value.startsWith("-") && value !== "-") {
        if (/^-[a-hj-zA-Z]*[ef]$/.test(value)) {
          scriptFromOption = true;
          i += 1;
        } else if (/^-[a-hj-zA-Z]*l$/.test(value)) {
          i += 1;
        }
        continue;
      }
      files.push(args[i]);
    }
    return this.checkAll(scriptFromOption ? files : files.slice(1), cwd);
  }

  git(args, cwd) {
    let repo = cwd;
    let index = 0;
    const takesValue = new Set(["-c", "--exec-path", "--namespace", "--super-prefix", "--config-env"]);
    while (index < args.length) {
      const value = args[index].value;
      if (value === "-C") {
        const next = args[index + 1];
        if (!next || next.subs.length) return null;
        const expanded = expandTarget(next.value, this.judge.env);
        if (expanded.partial) return null;
        repo = path.isAbsolute(expanded.value) ? path.resolve(expanded.value) : repo ? path.resolve(repo, expanded.value) : null;
        index += 2;
        continue;
      }
      if (value.startsWith("--work-tree=") || value.startsWith("--git-dir=")) {
        const expanded = expandTarget(value.slice(value.indexOf("=") + 1), this.judge.env);
        if (expanded.partial) return null;
        repo = path.isAbsolute(expanded.value) ? path.resolve(expanded.value) : repo ? path.resolve(repo, expanded.value) : null;
        index += 1;
        continue;
      }
      if (takesValue.has(value)) {
        index += 2;
        continue;
      }
      if (value.startsWith("-")) {
        index += 1;
        continue;
      }
      break;
    }
    const subcommand = args[index]?.value;
    if (!subcommand || !MUTATING_GIT.has(subcommand)) return null;
    const rest = args.slice(index + 1);
    if (subcommand === "clone") {
      const list = operandsSkipping(rest, new Set(["b", "o", "c", "u", "j", "branch", "origin", "config", "depth", "reference", "separate-git-dir", "template", "upload-pack", "jobs", "filter", "shallow-since", "shallow-exclude"]));
      if (list.length === 0) return null;
      const destination = list[1] ? list[1].value : basename(list[0].value).replace(/\.git$/, "");
      return this.judge.check(destination, repo);
    }
    if (subcommand === "init") {
      const list = operandsSkipping(rest, new Set(["b", "template", "separate-git-dir", "object-format", "initial-branch", "shared"]));
      return this.judge.check(list[0] ? list[0].value : ".", repo);
    }
    if (!repo) return null;
    return this.judge.check(repo, repo, { gitHome: HOME_CHECKOUT_GIT.has(subcommand) });
  }

  xargs(args, cwd, depth) {
    const takes = new Set(["I", "L", "n", "P", "s", "d", "E", "a", "replace", "max-lines", "max-args", "max-procs", "max-chars", "delimiter", "eof", "arg-file"]);
    let index = 0;
    while (index < args.length && args[index].value.startsWith("-")) {
      const value = args[index].value;
      const letter = value.length === 2 ? value[1] : "";
      index += takes.has(letter) || (value.startsWith("--") && !value.includes("=") && takes.has(value.slice(2))) ? 2 : 1;
    }
    const command = args[index];
    if (!command) return null;
    return this.command(basename(command.value), placeholders(args.slice(index + 1)), cwd, depth + 1, []);
  }

  find(args, cwd, depth) {
    const roots = [];
    let index = 0;
    while (index < args.length && !/^[-!(]/.test(args[index].value)) {
      roots.push(args[index]);
      index += 1;
    }
    const expression = args.slice(index);
    if (expression.some((word) => word.value === "-delete")) {
      const denial = this.checkAll(roots.length ? roots : [{ value: ".", subs: [] }], cwd, { recursive: true });
      if (denial) return denial;
    }
    for (let i = 0; i < expression.length; i += 1) {
      if (!["-exec", "-execdir", "-ok", "-okdir"].includes(expression[i].value)) continue;
      const end = expression.findIndex((word, j) => j > i && (word.value === ";" || word.value === "+"));
      const words = expression.slice(i + 1, end === -1 ? undefined : end);
      if (words[0]) {
        const denial = this.command(basename(words[0].value), placeholders(words.slice(1)), cwd, depth + 1, []);
        if (denial) return denial;
      }
    }
    return null;
  }

  shell(args, cwd, depth, stdinPayloads) {
    const commandFlag = args.findIndex((word) => /^-[a-zA-Z]*c$/.test(word.value));
    if (commandFlag !== -1 && args[commandFlag + 1]) return this.program(args[commandFlag + 1].value, cwd, depth + 1);
    if (operands(args).length === 0) {
      for (const payload of stdinPayloads) {
        const denial = this.program(payload, cwd, depth + 1);
        if (denial) return denial;
      }
    }
    return null;
  }

  interpreter(name, args, cwd, stdinPayloads) {
    const codes = [];
    const inlineFlags = new Set(["-c", "-e", "-E", "--eval", "-p", "--print"]);
    for (let i = 0; i < args.length; i += 1) {
      if (inlineFlags.has(args[i].value) && args[i + 1]) codes.push(args[i + 1].value);
      if (/^-[a-zA-Z]*[eE]$/.test(args[i].value) && args[i].value.length > 2 && args[i + 1]) codes.push(args[i + 1].value);
    }
    const scriptGiven = codes.length > 0 || operands(args).some((word) => word.value !== "-");
    if (!scriptGiven) codes.push(...stdinPayloads);
    for (const code of codes) {
      const denial = this.checkAll(inlineCodeTargets(code).map((value) => ({ value, subs: [] })), cwd);
      if (denial) return denial;
    }
    // perl -i / ruby -i edit their file operands in place.
    const inPlace = name === "perl" ? /^-[0-9aclnpsuwx]*i/ : /^-[acdlnpswvy]*i/;
    if ((name === "perl" || name === "ruby") && args.some((word) => inPlace.test(word.value))) {
      const list = operandsSkipping(args, new Set(["e", "E", "I", "M"]));
      const files = codes.length > 0 ? list : list.slice(1);
      return this.checkAll(files, cwd);
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Decision and reasons.
// ---------------------------------------------------------------------------

const DISPATCH = "register the request and dispatch a worker instead: classify it under the AGENTS.md intake contract, then bin/fm-brief.sh followed by bin/fm-spawn.sh (bin/fm-scout.sh for a scout)";

function reasonFor(denial, tool) {
  const where = `${tool} would write ${denial.target}`;
  switch (denial.code) {
    case "primary-write-project":
      return `${where}, inside a project clone. The firstmate primary never changes a project itself: ${DISPATCH}. Only a concrete captain-approved project operation (AGENTS.md hard rule 1) may proceed, after recording that approval with bin/fm-primary-write-grant.sh grant.`;
    case "primary-write-grant-record":
      return `${where}, a primary write grant record. Grants are created and revoked only through bin/fm-primary-write-grant.sh.`;
    case "primary-delete": return `Refused unsafe or unresolved recursive delete: ${denial.target}.`;
    case "primary-privilege": return "The primary never uses sudo or privilege escalation.";
    case "primary-secret": return `Secrets must never be printed: ${denial.target}.`;
    default:
      return `${where}, outside the permitted direct-operation paths: ${DISPATCH}. See docs/primary-write-guard.md.`;
  }
}

function decision(input) {
  const judge = new Judge(input);
  let denial = null;
  if (input.tool === "Read" && judge.host) {
    for (const target of input.paths) { denial = judge.secret(target, input.cwd); if (denial) break; }
  } else if (input.tool === "HostPath") {
    for (const raw of input.paths) {
      const expanded = expandTarget(raw, input.env);
      const target = canonical(path.resolve(expanded.value));
      if (/[\r\n\t]/.test(raw) || expanded.partial || !path.isAbsolute(expanded.value) || judge.isProject(target) || judge.homeCheckouts.some((root) => within(target, root) || within(root, target))) {
        denial = { code: "primary-write", target: raw }; break;
      }
    }
  } else if (FILE_TOOLS.has(input.tool)) {
    for (const target of input.paths) {
      denial = judge.check(target, input.cwd);
      if (denial) break;
    }
  } else if (SHELL_TOOLS.has(input.tool)) {
    if (input.command) denial = new ShellAnalyzer(judge).program(input.command, input.cwd);
  } else if (PATCH_TOOLS.has(input.tool)) {
    for (const target of patchTargets(input.command)) {
      denial = judge.check(target, input.cwd);
      if (denial) break;
    }
  }
  if (!denial) { judge.audit(); return { decision: "allow" }; }
  return { decision: "deny", code: denial.code, reason: reasonFor(denial, input.tool) };
}

function parseArguments(argv) {
  const result = { tool: "", cwd: "", command: "", paths: [], allow: [], allowFiles: [], allowPrefixes: [], grants: [], protect: [], projects: "", homeCheckouts: [], projectRoots: [] };
  const repeated = { "--project-root": "projectRoots", "--path": "paths", "--allow": "allow", "--allow-file": "allowFiles", "--allow-prefix": "allowPrefixes", "--grant": "grants", "--protect": "protect", "--home-checkout": "homeCheckouts" };
  const single = { "--stale-index-lock": "staleIndexLock", "--system-root": "systemRoot", "--host-mode": "hostMode", "--audit-log": "auditLog", "--tool": "tool", "--cwd": "cwd", "--command": "command", "--projects": "projects" };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (!(name in repeated) && !(name in single)) throw new Error(`unknown argument: ${name}`);
    if (i + 1 >= argv.length) throw new Error(`${name} requires a value`);
    if (name in repeated) result[repeated[name]].push(argv[i + 1]);
    else result[single[name]] = argv[i + 1];
    i += 1;
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    const result = decision({ ...args, env: process.env });
    if (result.decision === "allow") {
      if (args.tool === "HostPath") {
        for (const raw of args.paths) process.stdout.write(canonical(path.resolve(expandTarget(raw, process.env).value)) + "\n");
      } else process.stdout.write("allow\n");
    } else {
      process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      if (args.tool === "HostPath") process.exitCode = 2;
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
