# Public export from a private operator repository

An operator repository can contain private history even when its current tracked tree appears generic.
Publish from independently verified public history, with a reviewed content patch, so local commits, authors, messages, branches and tags never travel with it.
The original upstream license and attribution remain intact.
The export does not grant publication authority or configure a remote.

## Prepare a candidate

`bin/fm-public-export.py --help` owns the exact interface and refusal rules.
The [manifest](public-export-manifest.json) owns the allowed tracked roots, excluded private paths, required files and supported export-only managed-block removal.
The exporter reads only the selected committed tree and writes to a new directory outside the source checkout.
It does not read working overlays or copy `.git`, local refs, the index, config, runtime state, project clones, reports, validation output or untracked files.
Review newly introduced content before committing it; the export cannot recover an accidentally committed secret from local history.

Pin full source and public-base commit IDs.
Independently verify the base and its tree on the public upstream, and retain that verification privately.
Remote names and a local merge-base calculation alone are not proof that a commit is public.
The source must descend from that base; use the public ancestor of the customized source, not an unrelated current upstream tip.
Run the exporter after committing the desired local improvements:

```sh
python3 bin/fm-public-export.py \
  --source "$SOURCE_COMMIT" \
  --public-base "$VERIFIED_PUBLIC_BASE" \
  --output "$NEW_EXPORT_DIRECTORY" \
  --deny-file "$PRIVATE_LITERAL_DENY_FILE"
```

The optional private deny file contains one literal sensitive identifier per line, such as a local project name or private service hostname.
Its values are not printed or exported.
The built-in scan refuses introduced home paths, tailnet addresses, notification destinations and credential-shaped values, and refuses changed binary content that cannot be reviewed as text.
Exact examples already present in the independently verified public base are preserved; credential-shaped values are always refused.
This heuristic is a guard, not proof that all personal data has been found.
Review the entire patch, including strings, URLs, prompts, fixture captures, executable configuration and additions under allowed directories.
Retain legitimate generic upstream examples and licensed assets.

The resulting `tree/` is the candidate public content and `changes.patch` is a Git binary patch against the pinned public base.
`receipt.json` is private provenance: source commit/tree, public base, resulting public tree, manifest and patch hashes, per-file modes/hashes, exclusions and sanitization counts.
Keep that receipt and the source attestation outside the public repository.
The public content does not include local commit metadata, operational history or unrelated frozen branches.

Managed integration blocks in committed `AGENTS.md` are removed only from the export for the manifest's recognized block names.
The remaining supervisor contract is preserved; unknown or malformed managed blocks refuse export.
Uncommitted operator headers are never read, and neither the operator file nor the selected source commit is edited.
No hook installation, trust setting or notification preference is changed.

## First publication

Use a separate fresh clone obtained from the verified public upstream; never clone or mirror the private operator repository for publication.
The publishing operator owns this checkout and the exact personal repository target.
In that separate clone, select the verified public base on a new publication branch, then check and apply the exported patch:

```sh
git apply --check /path/to/export/changes.patch
git apply --index /path/to/export/changes.patch
git write-tree
```

Compare the resulting tree ID with the private receipt's `public_tree` before committing.
Review the staged diff and rerun the relevant tests against the candidate.
Commit with an intentionally public-safe identity and message, keeping attribution and the license.
Only after that review and publication authorization should the publishing operator add the exact personal target and push that single branch.
Never use `--all`, `--mirror`, `--tags`, a bundle from the operator repository, or an operator-history merge.

## Later improvements

Keep runtime customization in the existing ignored operational home and portable changes in source commits.
Export the next pinned source against the same verified public base, retaining both old and new patches and receipts privately.
In a clean checkout of the public fork, check that reversing the previous patch is possible, reverse it, then check and apply the new patch.
This produces the new exported tree on the existing safe public history, without importing operator history.
If the public fork has independent changes, a reverse/apply check may fail; preserve that work and reconcile the content deliberately rather than forcing a snapshot replacement.
Compare the resulting tree or reviewed reconciliation, validate it, and commit the delta with public-safe metadata.
An upstream update or manifest change requires renewed base verification and patch review.
The exporter never pushes, adds remotes, edits the live home or changes an active instance.
