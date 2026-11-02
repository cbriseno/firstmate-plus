#!/usr/bin/env node
// Semantic policy for the primary write guard: does this tool call make the
// PRIMARY firstmate session write outside its private operational paths?
//
// A firstmate primary delegates every actionable request to a worker; its own
// direct writes stay inside its private operational state (AGENTS.md section 1).
// Nothing enforced that before this guard, so a primary could edit the
// captain's dotfiles or user configuration itself instead of dispatching a
// worker. This policy decides one thing: whether each write target of a tool
// call lies inside the allowed paths the transport passes in. The transport
// (bin/fm-primary-write-pretool-check.sh) owns primary-home scope, the escape
// hatch, the allowed-path set, and harness rendering.
// See docs/primary-write-guard.md for the complete contract, carve-outs, and
// residual limits.
//
// Shell lexing is imported from bin/fm-arm-command-policy.mjs, the sole owner
// of firstmate's shell classification. This policy never evaluates, expands,
// sources, or runs any byte of the submitted command; it reads lexical command
// positions, redirection targets, and literal inline-code paths only. Its
// threat model is agent mistakes, not deliberate obfuscation: a target it
// cannot resolve to a literal path is allowed unless every completion of its
// literal prefix is already outside the allowed paths.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import path from "node:path";
import { realpathSync } from "node:fs";
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
    this.allowRoots = options.allow.map((root) => canonical(path.resolve(root)));
    this.allowFiles = options.allowFiles.map((file) => canonical(path.resolve(file)));
    this.protect = options.protect.map((root) => canonical(path.resolve(root)));
    this.grants = options.grants.map((root) => canonical(path.resolve(root)));
    // Name prefixes such as "<home>/scratchpad": the directory part is
    // canonicalized, the trailing name stem is kept as typed.
    this.allowPrefixes = options.allowPrefixes.map((prefix) => path.join(canonical(path.dirname(path.resolve(prefix))), path.basename(prefix)));
    this.projects = options.projects ? canonical(path.resolve(options.projects)) : "";
    this.homeCheckouts = options.homeCheckouts.map((root) => canonical(path.resolve(root)));
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

  // Returns null to allow, or a deny {code, target}.
  check(raw, cwd, { gitHome = false } = {}) {
    const expanded = expandTarget(raw, this.env);
    let value = expanded.value;
    if (!value) return null;
    if (!path.isAbsolute(value)) {
      if (!cwd) return null;
      value = path.join(cwd, value);
    }
    if (expanded.partial) {
      // Keep the trailing slash or partial component: "/srv/me/.con" must stay
      // a prefix of "/srv/me/.config", not collapse to "/srv/me".
      const prefix = path.resolve(value) + (value.endsWith("/") ? "/" : "");
      if (this.prefixCanBeAllowed(prefix) || this.prefixCanBeAllowed(canonical(path.resolve(value)))) return null;
      return this.denial(path.resolve(value), raw);
    }
    const resolved = path.resolve(value);
    if (DEVICE_FILES.has(resolved) || DEVICE_PREFIXES.some((prefix) => resolved.startsWith(prefix))) return null;
    const target = canonical(resolved);
    if (this.protect.some((root) => within(target, root))) return { code: "primary-write-grant-record", target };
    // A live captain-approval grant is the only way into a project clone; it
    // outranks every other allowance, so a temp-dir or home-root allowance can
    // never reach a project by accident.
    if (this.grants.some((root) => within(target, root))) return null;
    if (this.projects && within(target, this.projects)) return this.denial(target, raw);
    if (this.allowedPath(target)) return null;
    if (gitHome && this.homeCheckouts.some((root) => within(target, root)) && !(this.projects && within(target, this.projects))) return null;
    return this.denial(target, raw);
  }

  denial(target, raw) {
    if (this.projects && within(target, this.projects)) return { code: "primary-write-project", target, raw };
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
    for (const node of nodes) {
      const result = this.node(node, current, depth);
      if (result.denial) return result.denial;
      current = result.cwd;
    }
    return null;
  }

  node(rawTokens, cwd, depth) {
    // The shared lexer reads a bare `{}` (find -exec, xargs -I{}) as an empty
    // brace group; bash treats it as an ordinary word, so restore it as one.
    const tokens = rawTokens.map((token) => (token.type === "group" && token.kind === "brace" && !token.content.trim()
      ? { type: "word", value: "{}", literal: true, subs: [], quoted: false, unquotedExpansion: true }
      : token));
    const check = (raw, options) => this.judge.check(raw, cwd, options);
    // Redirection targets.
    for (let i = 0; i < tokens.length; i += 1) {
      const token = tokens[i];
      if (token.type !== "redir" || token.inlineTarget || INPUT_REDIRECTIONS.has(token.value)) continue;
      const target = tokens[i + 1];
      if (!target || target.type !== "word" || target.subs.length) continue;
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
      if (word.subs.length) continue;
      const denial = this.judge.check(word.value, cwd, options);
      if (denial) return denial;
    }
    return null;
  }

  command(name, args, cwd, depth, stdinPayloads) {
    switch (name) {
      case "tee":
        return this.checkAll(operandsSkipping(args, new Set(["output-error"])), cwd);
      case "cp":
      case "install":
      case "ln":
      case "rsync": {
        const targetDir = optionValue(args, "t", "target-directory");
        if (targetDir) return this.checkAll([targetDir], cwd);
        const list = operandsSkipping(args, new Set(["m", "o", "g", "S", "mode", "owner", "group", "suffix"]));
        if (name === "install" && args.some((word) => word.value === "-d" || word.value === "--directory")) return this.checkAll(list, cwd);
        if (list.length < 2) return null;
        const destination = list.at(-1);
        if (name === "rsync" && /^[^/]*:/.test(destination.value)) return null;
        return this.checkAll([destination], cwd);
      }
      case "mv": {
        const targetDir = optionValue(args, "t", "target-directory");
        const list = operandsSkipping(args, new Set(["S", "suffix"]));
        return this.checkAll(targetDir ? [targetDir, ...list] : list, cwd);
      }
      case "rm":
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
      const denial = this.checkAll(roots.length ? roots : [{ value: ".", subs: [] }], cwd);
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
    default:
      return `${where}, outside this home's private operational paths (state/, data/, config/, .lavish/, a temp dir). The firstmate primary does not do the work itself - not project work, and not changes to the captain's shell, dotfiles, user configuration, or installed tools either: ${DISPATCH}. Do not route around this refusal with another tool; docs/primary-write-guard.md owns the carve-outs.`;
  }
}

function decision(input) {
  const judge = new Judge(input);
  let denial = null;
  if (FILE_TOOLS.has(input.tool)) {
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
  if (!denial) return { decision: "allow" };
  return { decision: "deny", code: denial.code, reason: reasonFor(denial, input.tool) };
}

function parseArguments(argv) {
  const result = { tool: "", cwd: "", command: "", paths: [], allow: [], allowFiles: [], allowPrefixes: [], grants: [], protect: [], projects: "", homeCheckouts: [] };
  const repeated = { "--path": "paths", "--allow": "allow", "--allow-file": "allowFiles", "--allow-prefix": "allowPrefixes", "--grant": "grants", "--protect": "protect", "--home-checkout": "homeCheckouts" };
  const single = { "--tool": "tool", "--cwd": "cwd", "--command": "command", "--projects": "projects" };
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
      process.stdout.write("allow\n");
    } else {
      process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
