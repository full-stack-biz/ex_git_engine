# libgit2 API Reference

libgit2 is a portable C library that implements Git functionality. GitRekt wraps libgit2 via Erlang NIFs to provide Git access from Elixir.

Sources:
- https://libgit2.org/
- https://libgit2.github.io/libgit2/ (API documentation)
- https://github.com/libgit2/libgit2/tree/main/docs

## Table of Contents

- [libgit2 Overview](#libgit2-overview)
- [libgit2 Versioning](#libgit2-versioning)
- [Core Concepts](#core-concepts)
- [Repository Operations](#repository-operations)
- [Object Lookups](#object-lookups)
- [Commits](#commits)
- [Trees and Blobs](#trees-and-blobs)
- [References](#references)
- [Index (Staging Area)](#index-staging-area)
- [Status and Diff](#status-and-diff)
- [Object ID (OID) Handling](#object-id-oid-handling)
- [Error Handling](#error-handling)
- [Thread Safety](#thread-safety)
- [NIF Wrapper Implications (GitRekt)](#nif-wrapper-implications-gitrekt)
- [Common libgit2 Patterns](#common-libgit2-patterns)
- [Common Pitfalls](#common-pitfalls)
- [Version-Specific Considerations](#version-specific-considerations)
- [Debugging libgit2](#debugging-libgit2)

---

## libgit2 Overview

**libgit2** is a pure C implementation of Git. It provides:
- Repository access (open, create, list)
- Object access (commits, trees, blobs, tags)
- Reference management (branches, tags, HEAD)
- Index operations (staging area)
- Working directory operations
- Diff generation
- Packfile handling
- Wire protocol (fetch/push)

**Not provided by libgit2**:
- Command-line interface (that's git CLI)
- Remote handling (network layer; libgit2 provides protocol but not transport)
- Hosting/authentication logic (applications build on top)

**Key design**: libgit2 is a library, not a service. It's designed for embedding in applications.

---

## libgit2 Versioning

### Version Scheme

libgit2 uses semantic versioning: `MAJOR.MINOR.PATCH`

- **MAJOR** — Breaking API changes
- **MINOR** — New features, backward compatible
- **PATCH** — Bug fixes, backward compatible

Current stable: libgit2 1.x (released 2020+)

### API Stability

libgit2 v1.0+ guarantees API stability within the major version. Upgrading 1.0→1.5 is safe; upgrading 1.x→2.0 may require code changes.

---

## Core Concepts

### Git Objects

libgit2 represents Git objects as:

- **blob** — File contents
- **tree** — Directory listing (contains tree entries)
- **commit** — Snapshot with metadata (author, message, parents)
- **tag** — Named reference to an object with metadata

All objects have an OID (Object Identifier), a 20-byte (SHA-1) or 32-byte (SHA-256) hash.

### References (Refs)

libgit2 manages refs:

- **Direct refs** — Point to an OID (e.g., `refs/heads/main` → commit SHA)
- **Symbolic refs** — Point to another ref (e.g., `HEAD` → `refs/heads/main`)

### Object Database (ODB)

libgit2's object database:

- Stores objects in loose format (`.git/objects/xx/yyyyyy...`)
- Stores objects in packfile format (`.git/objects/pack/`)
- Automatically chooses loose or pack based on efficiency
- Handles object deduplication (same content = same OID)

### Index (Staging Area)

The index represents the staging area:

- Tracks which files are staged for commit
- Records file paths, modes, OIDs, metadata
- Created on `git add` operations
- Used to build commit trees

---

## Repository Operations

### Opening a Repository

```c
int git_repository_open(git_repository **out, const char *path);
```

Opens an existing Git repository at `path` (must contain `.git/` or be a bare repo).

Returns:
- `0` on success
- `GIT_ENOTFOUND` if repository doesn't exist
- Other error codes on failure

### Creating a Repository

```c
int git_repository_init(git_repository **out, const char *path, unsigned is_bare);
```

Creates a new repository. `is_bare` indicates whether it's bare (no working directory).

### Repository Configuration

```c
git_config *config = NULL;
git_repository_config(&config, repo);
git_config_get_string_buf(&buf, config, "user.name");
```

Access git config (user.name, user.email, etc.).

### Working Directory

```c
const char *workdir = git_repository_workdir(repo);
```

Returns path to working directory (NULL for bare repos).

---

## Object Lookups

### By OID

```c
git_object *obj = NULL;
git_object_lookup(&obj, repo, &oid, GIT_OBJECT_ANY);
```

Look up any object by its OID.

Possible types:
- `GIT_OBJECT_COMMIT`
- `GIT_OBJECT_TREE`
- `GIT_OBJECT_BLOB`
- `GIT_OBJECT_TAG`
- `GIT_OBJECT_ANY` (any type)

### By Reference Name

```c
git_reference *ref = NULL;
git_reference_lookup(&ref, repo, "refs/heads/main");

git_object *obj = NULL;
git_reference_peel(&obj, ref, GIT_OBJECT_COMMIT);
```

Look up a reference, optionally dereferencing to an object of a specific type.

### Revisions

```c
git_revwalk *walker = NULL;
git_revwalk_new(&walker, repo);
git_revwalk_push(walker, &commit_oid);
git_revwalk_hide(walker, &base_oid);  // Exclude these

git_oid oid;
while (git_revwalk_next(&oid, walker) == 0) {
    // Process oid
}
```

Walk commit history with include/exclude logic.

---

## Commits

### Accessing Commit Data

```c
git_commit *commit = NULL;
git_object_lookup((git_object **)&commit, repo, &oid, GIT_OBJECT_COMMIT);

// Author
const git_signature *author = git_commit_author(commit);
const char *name = author->name;
const char *email = author->email;
git_time_t time = author->when.time;

// Message
const char *message = git_commit_message(commit);

// Tree
git_tree *tree = NULL;
git_commit_tree(&tree, commit);

// Parents
unsigned int parent_count = git_commit_parentcount(commit);
git_commit *parent = NULL;
git_commit_parent(&parent, commit, 0);  // Get parent 0
```

Access commit metadata: author, message, tree, parents.

### Creating Commits

```c
git_signature *sig = NULL;
git_signature_now(&sig, "User Name", "user@example.com");

git_tree *tree = NULL;
git_tree_lookup(&tree, repo, &tree_oid);

git_oid new_commit_oid;
git_commit_create_v(&new_commit_oid, repo, "HEAD", sig, sig,
    NULL,  // message encoding (NULL = UTF-8)
    "Commit message",
    tree,
    1,  // parent count
    parent_commit  // parent commits
);
```

Create a new commit with given parents and tree.

---

## Trees and Blobs

### Accessing Trees

```c
git_tree *tree = NULL;
git_tree_lookup(&tree, repo, &oid);

// Iterate entries
size_t count = git_tree_entrycount(tree);
for (size_t i = 0; i < count; i++) {
    const git_tree_entry *entry = git_tree_entry_byindex(tree, i);
    const char *name = git_tree_entry_name(entry);
    const git_oid *oid = git_tree_entry_id(entry);
    git_filemode_t mode = git_tree_entry_filemode(entry);
}
```

Access tree entries (directory listing).

### Accessing Blobs

```c
git_blob *blob = NULL;
git_blob_lookup(&blob, repo, &oid);

// File contents
const void *data = git_blob_rawcontent(blob);
git_object_size_t size = git_blob_rawsize(blob);

// Check if binary
int is_binary = git_blob_is_binary(blob);
```

Access blob data (file contents).

### Walking Trees

```c
int treewalk_callback(const char *root, const git_tree_entry *entry, void *payload) {
    // Process entry
    // Return 0 to continue, GIT_TREEWALK_SKIP to skip subtree
    return 0;
}

git_tree_walk(tree, GIT_TREEWALK_PRE, treewalk_callback, NULL);
```

Recursively walk tree structure.

---

## References

### Looking Up References

```c
git_reference *ref = NULL;
git_reference_lookup(&ref, repo, "refs/heads/main");

const char *name = git_reference_name(ref);
const git_oid *target = git_reference_target(ref);
const char *symbolic = git_reference_symbolic_target(ref);

git_reference_type type = git_reference_type(ref);  // GIT_REFERENCE_DIRECT or GIT_REFERENCE_SYMBOLIC
```

Look up references by name.

### Creating/Updating References

```c
git_reference *ref = NULL;

// Create direct reference
git_reference_create(&ref, repo, "refs/heads/newbranch", &oid, 0, NULL);

// Create symbolic reference
git_reference_symbolic_create(&ref, repo, "refs/heads/alias", "refs/heads/main", 0, NULL);

// Update existing
git_reference_set_target(&ref, ref, &new_oid, NULL);
```

Create and update references.

### Deleting References

```c
git_reference_delete(ref);
```

Delete a reference.

### Reference Iteration

```c
git_reference_iterator *iter = NULL;
git_reference_iterator_new(&iter, repo);

const char *ref_name = NULL;
while (git_reference_next_name(&ref_name, iter) == 0) {
    // Process ref_name
}

git_reference_iterator_free(iter);
```

Iterate all references in repository.

### HEAD Resolution

```c
git_reference *head_ref = NULL;
git_repository_head(&head_ref, repo);

git_object *head_obj = NULL;
git_reference_peel(&head_obj, head_ref, GIT_OBJECT_COMMIT);
```

Get current HEAD and resolve to commit.

---

## Index (Staging Area)

### Loading Index

```c
git_index *index = NULL;
git_repository_index(&index, repo);
```

Load the repository's index (staging area).

### Adding Files to Index

```c
git_index_add_bypath(index, "path/to/file.txt");

// Write changes back to disk
git_index_write(index);
```

Stage files in index.

### Removing Files

```c
git_index_remove_bypath(index, "path/to/file.txt");
git_index_write(index);
```

Remove files from index.

### Clearing Index

```c
git_index_clear(index);
git_index_write(index);
```

Clear entire index.

### Creating Tree from Index

```c
git_oid tree_oid;
git_index_write_tree(&tree_oid, index, repo);

git_tree *tree = NULL;
git_tree_lookup(&tree, repo, &tree_oid);
```

Create a commit tree from the current index.

---

## Status and Diff

### File Status

```c
unsigned int status = 0;
git_status_file(&status, repo, "path/to/file.txt");

// Check flags
if (status & GIT_STATUS_WT_MODIFIED) { }      // Modified in working directory
if (status & GIT_STATUS_INDEX_MODIFIED) { }   // Modified in index
if (status & GIT_STATUS_WT_UNTRACKED) { }     // Untracked file
```

Check file status (modified, untracked, staged, etc.).

### Generating Diffs

```c
git_diff *diff = NULL;
git_diff_index_to_workdir(&diff, repo, NULL, NULL);  // Diff index vs working directory

// Or
git_diff_tree_to_index(&diff, repo, tree, index, NULL);  // Diff tree vs index

git_diff_foreach(diff, NULL, NULL, hunk_callback, line_callback, payload);
```

Generate diffs between different states.

---

## Object ID (OID) Handling

### OID Sizes

- SHA-1: 20 bytes (`GIT_OID_SHA1`)
- SHA-256: 32 bytes (`GIT_OID_SHA256`)

### OID Conversion

```c
git_oid oid;
git_oid_fromstr(&oid, "abc123def456...");  // Parse from hex string

char hex_str[GIT_OID_MAX_HEXSIZE];
git_oid_tostr(hex_str, sizeof(hex_str), &oid);  // Convert to hex string
```

Convert between binary and hex representations.

---

## Error Handling

### Return Codes

libgit2 uses integer return codes:

- `0` — Success
- `GIT_OK` — Success (same as 0)
- Negative values — Error codes

Common errors:
- `GIT_ENOTFOUND` — Object/ref not found
- `GIT_EEXISTS` — Object/ref already exists
- `GIT_EINVALID` — Invalid argument
- `GIT_EAUTH` — Authentication required
- `GIT_ECONFLICT` — Conflict (e.g., merge conflict)

### Error Details

```c
const git_error *error = git_error_last();
if (error) {
    int klass = error->klass;
    const char *message = error->message;
}
```

Get detailed error message after a failed operation.

### Memory Management

libgit2 manages memory for returned objects:

```c
git_object *obj = NULL;
git_object_lookup(&obj, repo, &oid, GIT_OBJECT_ANY);
// ... use obj ...
git_object_free(obj);  // Must free when done
```

Always free objects when done. Failure to free causes memory leaks.

---

## Thread Safety

### Repository Objects

Git repository objects are **not thread-safe**. Multiple threads must not:
- Access the same repository object simultaneously
- Call operations on the same repository from different threads

### Solution

- Create separate repository handles per thread
- Use locking/mutex to serialize access
- Use GitAgent (in GitRekt) for safe concurrent access via message passing

### Object References

Once created, Git object references (commits, trees, blobs) can be:
- Safely passed between threads if not modified
- Safely freed from any thread
- Used read-only from multiple threads

---

## NIF Wrapper Implications (GitRekt)

### Memory in NIFs

NIFs run in the Erlang VM, not as separate processes. Careful memory management is required:

- libgit2 objects must be freed explicitly
- Memory leaks in NIF code affect the entire VM
- Crashes in C code (segfaults, etc.) crash the entire VM

**GitRekt's `Git` module handles this** by:
- Wrapping all libgit2 calls in C code
- Freeing objects before returning to Erlang
- Returning error tuples instead of letting C errors propagate

### NIF Safety Rules (From CLAUDE.md)

- Keep error handling at boundaries (in NIF layer)
- Avoid risky operations in hot paths (expensive copying, allocation)
- Don't assume VM will catch C errors; it won't

### Serialization via GitAgent

Since libgit2 repository objects aren't thread-safe, GitRekt uses:

- `GitAgent` GenServer to serialize all repository access
- One repository handle per agent
- Message passing ensures only one operation at a time
- Caller blocks until operation completes

---

## Common libgit2 Patterns

### Pattern: Load and Iterate Commits

```c
git_revwalk *walker = NULL;
git_revwalk_new(&walker, repo);
git_revwalk_push_head(walker);  // Start from HEAD

git_oid oid;
while (git_revwalk_next(&oid, walker) == 0) {
    git_commit *commit = NULL;
    git_object_lookup((git_object **)&commit, repo, &oid, GIT_OBJECT_COMMIT);
    // ... process commit ...
    git_object_free((git_object *)commit);
}
git_revwalk_free(walker);
```

### Pattern: Load Tree Recursively

```c
void process_tree(git_tree *tree, const char *path) {
    size_t count = git_tree_entrycount(tree);
    for (size_t i = 0; i < count; i++) {
        const git_tree_entry *entry = git_tree_entry_byindex(tree, i);
        
        if (git_tree_entry_type(entry) == GIT_OBJECT_TREE) {
            git_tree *subtree = NULL;
            git_tree_lookup(&subtree, repo, git_tree_entry_id(entry));
            process_tree(subtree, new_path);
            git_object_free((git_object *)subtree);
        }
    }
}
```

### Pattern: Check if Ref Exists

```c
git_reference *ref = NULL;
int exists = (git_reference_lookup(&ref, repo, "refs/heads/main") == 0);
if (ref) git_reference_free(ref);
```

### Pattern: Safe Object Lookup

```c
git_object *obj = NULL;
int result = git_object_lookup(&obj, repo, &oid, GIT_OBJECT_COMMIT);
if (result != 0) {
    // Handle error: object not found, wrong type, etc.
}
// ... use obj ...
if (obj) git_object_free(obj);
```

---

## Common Pitfalls

| Pitfall | Issue | Solution |
|---------|-------|----------|
| Not freeing objects | Memory leak | Call `git_*_free()` for every allocated object |
| Accessing NULL objects | Segfault/crash | Always check return codes, handle NULL |
| Wrong object type cast | Undefined behavior | Verify type before casting |
| Modifying shared objects | Corruption | Never modify objects; create new ones |
| Not handling errors | Silent failures | Check return codes for every libgit2 call |
| Concurrent repository access | Data corruption | Serialize access (GitAgent does this) |
| Assuming success | Crashes | libgit2 returns error codes, doesn't throw |
| Symbolic ref loops | Infinite loop | Follow symbolic refs with depth limit |

---

## Version-Specific Considerations

### libgit2 1.0+

Modern stable version. Recommended for GitRekt.

Key features:
- Stable API
- SHA-256 support
- Modern error handling

### libgit2 0.28

Older version, still used in some systems.

Differences:
- Some functions have different signatures
- Different error handling in edge cases
- No SHA-256 support

GitRekt should target 1.0+ unless legacy support required.

---

## Debugging libgit2

### Enable Debug Output

```c
git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, "/etc/ssl/certs/ca-bundle.crt", NULL);
```

Configure libgit2 behavior.

### Check Build Configuration

```bash
git --version  # System git version
pkg-config --modversion libgit2  # libgit2 version
```

Verify installed versions.

### Common libgit2 Issues

| Symptom | Likely Cause | Check |
|---------|--------------|-------|
| GIT_ENOTFOUND on lookup | Object/ref doesn't exist | Verify OID/ref name is correct |
| GIT_EINVALID on creation | Invalid parameters | Check parameter types/values |
| Segfault on free | Double-free or wrong pointer | Ensure free called once per malloc |
| Slow operations | Not using threads efficiently | GitAgent serializes intentionally |
| Memory growth | Leaking objects | Audit all `git_*_lookup`/`git_*_new` for corresponding free |
