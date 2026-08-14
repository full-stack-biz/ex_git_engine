#include "erl_nif.h"
#include "repository.h"
#include "reference.h"
#include "oid.h"
#include "object.h"
#include "odb.h"
#include "commit.h"
#include "tree.h"
#include "blob.h"
#include "tag.h"
#include "library.h"
#include "revwalk.h"
#include "pathspec.h"
#include "diff.h"
#include "index.h"
#include "signature.h"
#include "revparse.h"
#include "reflog.h"
#include "graph.h"
#include "config.h"
#include "pack.h"
#include "worktree.h"
#include "merge.h"
#include "blame.h"
#include "ex_git_engine.h"
#include <stdio.h>
#include <string.h>
#include <git2.h>

ErlNifResourceType *git_engine_repository_type;
ErlNifResourceType *git_engine_odb_type;
ErlNifResourceType *git_engine_odb_writepack_type;
ErlNifResourceType *git_engine_ref_iter_type;
ErlNifResourceType *git_engine_object_type;
ErlNifResourceType *git_engine_revwalk_type;
ErlNifResourceType *git_engine_diff_type;
ErlNifResourceType *git_engine_index_type;
ErlNifResourceType *git_engine_config_type;
ErlNifResourceType *git_engine_pack_type;
ErlNifResourceType *git_engine_worktree_type;

git_engine_atoms atoms;

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM load_info)
{
	git_libgit2_init();

	git_engine_repository_type = enif_open_resource_type(env, NULL,
		"repository_type", git_engine_repository_free, ERL_NIF_RT_CREATE, NULL);

	if (git_engine_repository_type == NULL)
		return -1;

	git_engine_odb_type = enif_open_resource_type(env, NULL,
		"odb_type", git_engine_odb_free, ERL_NIF_RT_CREATE, NULL);

	if (git_engine_odb_type == NULL)
		return -1;

	git_engine_odb_writepack_type = enif_open_resource_type(env, NULL,
		"odb_writepack_type", git_engine_odb_writepack_free, ERL_NIF_RT_CREATE, NULL);

	if (git_engine_odb_writepack_type == NULL)
		return -1;

	git_engine_ref_iter_type = enif_open_resource_type(env, NULL,
		"ref_iter_type", git_engine_ref_iter_free, ERL_NIF_RT_CREATE, NULL);

	if (git_engine_ref_iter_type == NULL)
		return -1;

	git_engine_object_type = enif_open_resource_type(env, NULL,
		"object_type", git_engine_object_free, ERL_NIF_RT_CREATE, NULL);

	if (git_engine_object_type == NULL)
		return -1;

	git_engine_revwalk_type = enif_open_resource_type(env, NULL,
		"revwalk_type", git_engine_revwalk_free, ERL_NIF_RT_CREATE, NULL);

	if (git_engine_revwalk_type == NULL)
		return -1;

	git_engine_diff_type = enif_open_resource_type(env, NULL,
		"diff_type", git_engine_diff_free, ERL_NIF_RT_CREATE, NULL);

	if (git_engine_diff_type == NULL)
		return -1;

	git_engine_index_type = enif_open_resource_type(env, NULL,
		"index_type", git_engine_index_free, ERL_NIF_RT_CREATE, NULL);

	if (git_engine_index_type == NULL)
		return -1;

	git_engine_config_type = enif_open_resource_type(env, NULL,
		"config_type", git_engine_config_free, ERL_NIF_RT_CREATE, NULL);

	if (git_engine_config_type == NULL)
		return -1;

	git_engine_pack_type = enif_open_resource_type(env, NULL,
		"pack_type", git_engine_pack_free, ERL_NIF_RT_CREATE, NULL);

	if (git_engine_pack_type == NULL)
		return -1;

	git_engine_worktree_type = enif_open_resource_type(env, NULL,
		"worktree_type", git_engine_worktree_free, ERL_NIF_RT_CREATE, NULL);

	if (git_engine_worktree_type == NULL)
		return -1;

	atoms.ok = enif_make_atom(env, "ok");
	atoms.error = enif_make_atom(env, "error");
	atoms.nil = enif_make_atom(env, "nil");
	atoms.true = enif_make_atom(env, "true");
	atoms.false = enif_make_atom(env, "false");
	atoms.repository = enif_make_atom(env, "repository");
	atoms.oid = enif_make_atom(env, "oid");
	atoms.symbolic = enif_make_atom(env, "symbolic");
	atoms.commit = enif_make_atom(env, "commit");
	atoms.tree = enif_make_atom(env, "tree");
	atoms.blob = enif_make_atom(env, "blob");
	atoms.tag = enif_make_atom(env, "tag");
	atoms.format_patch = enif_make_atom(env, "patch");
	atoms.format_patch_header = enif_make_atom(env, "patch_header");
	atoms.format_raw = enif_make_atom(env, "raw");
	atoms.format_name_only = enif_make_atom(env, "name_only");
	atoms.format_name_status = enif_make_atom(env, "name_status");
	atoms.diff_opts_pathspec = enif_make_atom(env, "pathspec");
	atoms.diff_opts_context_lines = enif_make_atom(env, "context_lines");
	atoms.diff_opts_interhunk_lines = enif_make_atom(env, "interhunk_lines");
	atoms.undefined = enif_make_atom(env, "undefined");
	atoms.reflog_entry = enif_make_atom(env, "git_engine_reflog_entry");
	/* Revwalk */
	atoms.toposort    = enif_make_atom(env, "sort_topo");
	atoms.timesort    = enif_make_atom(env, "sort_time");
	atoms.reversesort = enif_make_atom(env, "sort_reverse");
	atoms.iterover    = enif_make_atom(env, "iterover");
	/* Indexer progress */
	atoms.indexer_total_objects = enif_make_atom(env, "total_objects");
	atoms.indexer_indexed_objects = enif_make_atom(env, "indexed_objects");
	atoms.indexer_received_objects = enif_make_atom(env, "received_objects");
	atoms.indexer_local_objects = enif_make_atom(env, "local_objects");
	atoms.indexer_total_deltas = enif_make_atom(env, "total_deltas");
	atoms.indexer_indexed_deltas = enif_make_atom(env, "indexed_deltas");
	atoms.indexer_received_bytes = enif_make_atom(env, "received_bytes");
	/* Errors */
	atoms.zlib_need_dict = enif_make_atom(env, "zlib_need_dict");
	atoms.zlib_data_error = enif_make_atom(env, "zlib_data_error");
	atoms.zlib_stream_error = enif_make_atom(env, "zlib_stream_error");
	atoms.enomem = enif_make_atom(env, "enomem");
	atoms.eunknown = enif_make_atom(env, "eunknown");
	atoms.estruct = enif_make_atom(env, "__struct__");
	atoms.emod = enif_make_atom(env, "Elixir.ExGitEngine.GitError");
	atoms.ex = enif_make_atom(env, "__exception__");
	atoms.emsg = enif_make_atom(env, "message");
	atoms.ecode = enif_make_atom(env, "code");

	return 0;
}

int upgrade(ErlNifEnv* env, void** priv_data, void** old_priv_data, ERL_NIF_TERM load_info)
{
	return 0;
}

static void unload(ErlNifEnv* env, void* priv_data)
{
	git_libgit2_shutdown();
}

ERL_NIF_TERM
git_engine_error(ErlNifEnv *env)
{
	const git_error *error;
	ErlNifBinary bin;
	size_t len;

	error = giterr_last();

	if (!error)
		return enif_make_tuple2(env, atoms.error, atoms.eunknown);

	if (error->klass == GITERR_NOMEMORY)
		return git_engine_oom(env);

	if (!error->message)
		return enif_make_tuple2(env, atoms.error, atoms.eunknown);

	len = strlen(error->message);
	if (!enif_alloc_binary(len, &bin))
		return git_engine_oom(env);

	memcpy(bin.data, error->message, len);

	return enif_make_tuple2(env, atoms.error, enif_make_binary(env, &bin));
}
ERL_NIF_TERM
git_engine_error_struct(ErlNifEnv *env, int code)
{
    ERL_NIF_TERM struct_term;
    ERL_NIF_TERM keys[] = {
        atoms.estruct,
        atoms.ex,
        atoms.emsg,
        atoms.ecode
    };

    const git_error *error = giterr_last();
    if (!error)
        return enif_make_tuple2(env, atoms.error, atoms.eunknown);

    size_t len = strlen(error->message);
    ErlNifBinary bin;
    if (!enif_alloc_binary(len, &bin))
        return git_engine_oom(env);

    memcpy(bin.data, error->message, len);
    ERL_NIF_TERM values[] = {
        atoms.emod,
        atoms.true,
        enif_make_binary(env, &bin),
        enif_make_int(env, code)
    };

    // Correctly handle the return value of enif_make_map_from_arrays
    int map_creation_status = enif_make_map_from_arrays(env, keys, values, 4, &struct_term);
    if (map_creation_status < 0) {
        // If map creation fails, return a general error
        return git_engine_error(env);
    }

    // Return the error map if map creation was successful
    return enif_make_tuple2(env, atoms.error, struct_term);
}


ERL_NIF_TERM
git_engine_oom(ErlNifEnv *env)
{
	return enif_make_tuple2(env, atoms.error, atoms.enomem);
}

git_strarray git_strarray_from_list(ErlNifEnv *env, ERL_NIF_TERM list)
{
	ErlNifBinary bin;
	ERL_NIF_TERM head, tail;
	unsigned int i, size;
	git_strarray array = { NULL, 0 };

	if (!enif_get_list_length(env, list, &size))
		return array;

	array.count = size;
	array.strings = malloc(sizeof(char*) * size);

	tail = list;
	for(i = 0; i < size; i++) {
		if (!enif_get_list_cell(env, tail, &head, &tail))
			return array;

		if (!enif_inspect_binary(env, head, &bin))
			return array;

		array.strings[i] = memcpy(malloc((bin.size+1) * sizeof(char)), bin.data, bin.size+1);
		array.strings[i][bin.size] = '\0';
	}

	return array;
}

int git_engine_terminate_binary(ErlNifBinary *bin)
{
	if (!enif_realloc_binary(bin, bin->size + 1))
		return 0;

	bin->data[bin->size - 1] = '\0';

	return 1;
}

int git_engine_string_to_bin(ErlNifBinary *bin, const char *str)
{
	size_t len;

	if (str == NULL)
		len = 0;
	else
		len = strlen(str);

	if (!enif_alloc_binary(len, bin))
		return -1;

	memcpy(bin->data, str, len);
	return 0;
}

static ErlNifFunc git_engine_funcs[] =
{
	{"repository_init", 3, git_engine_repository_init, 0},
	{"repository_open", 1, git_engine_repository_open, 0},
	{"repository_discover", 1, git_engine_repository_discover, 0},
	{"repository_bare?", 1, git_engine_repository_is_bare, 0},
	{"repository_empty?", 1, git_engine_repository_is_empty, 0},
	{"repository_get_path", 1, git_engine_repository_path, 0},
	{"repository_get_workdir", 1, git_engine_repository_workdir, 0},
	{"repository_get_odb", 1, git_engine_repository_odb, 0},
	{"repository_get_index", 1, git_engine_repository_index, 0},
	{"repository_get_config", 1, git_engine_repository_config, 0},
	{"repository_clone", 3, git_engine_repository_clone, ERL_NIF_DIRTY_JOB_IO_BOUND},
	{"odb_object_hash", 2, git_engine_odb_hash, 0},
	{"odb_object_exists?", 2, git_engine_odb_exists, 0},
	{"odb_read", 2, git_engine_odb_read, 0},
	{"odb_write", 3, git_engine_odb_write, 0},
	{"odb_write_pack", 2, git_engine_odb_write_pack, 0},
	{"odb_get_writepack", 1, git_engine_odb_get_writepack, 0},
	{"odb_writepack_append", 3, git_engine_odb_writepack_append, 0},
	{"odb_writepack_commit", 2, git_engine_odb_writepack_commit, 0},
	{"reference_list", 1, git_engine_reference_list, 0},
	{"reference_peel", 3, git_engine_reference_peel, 0},
	{"reference_to_id", 2, git_engine_reference_to_id, 0},
	{"reference_glob", 2, git_engine_reference_glob, 0},
	{"reference_lookup", 2, git_engine_reference_lookup, 0},
	{"reference_iterator", 2, git_engine_reference_iterator, 0},
	{"reference_next", 1, git_engine_reference_next, 0},
	{"reference_resolve", 2, git_engine_reference_resolve, 0},
	{"reference_create", 5, git_engine_reference_create, 0},
	{"reference_delete", 2, git_engine_reference_delete, 0},
	{"reference_dwim", 2,   git_engine_reference_dwim, 0},
	{"reference_log?", 2, git_engine_reference_has_log, 0},
	{"reflog_count", 2, git_engine_reflog_count, 0},
	{"reflog_read", 2, git_engine_reflog_read, 0},
	{"reflog_delete", 2, git_engine_reflog_delete, 0},
	{"graph_ahead_behind", 3, git_engine_graph_ahead_behind, 0},
	{"oid_fmt", 1, git_engine_oid_fmt, 0},
	{"oid_parse", 1, git_engine_oid_parse, 0},
	{"object_repository", 1, git_engine_object_repository, 0},
	{"object_lookup", 2, git_engine_object_lookup, 0},
	{"object_id", 1, git_engine_object_id, 0},
	{"object_zlib_inflate", 2, git_engine_object_zlib_inflate, 0},
	{"commit_parent", 2, git_engine_commit_parent, 0},
	{"commit_parent_count", 1, git_engine_commit_parent_count, 0},
	{"commit_tree", 1, git_engine_commit_tree, 0},
	{"commit_tree_id", 1, git_engine_commit_tree_id, 0},
	{"commit_create",  8, git_engine_commit_create, 0},
	{"commit_message", 1, git_engine_commit_message, 0},
	{"commit_author", 1, git_engine_commit_author, 0},
	{"commit_committer", 1, git_engine_commit_committer, 0},
	{"commit_time", 1, git_engine_commit_time, 0},
	{"commit_raw_header", 1, git_engine_commit_raw_header, 0},
	{"commit_header", 2, git_engine_commit_header, 0},
	{"commit_raw", 1, git_engine_commit_raw, 0},
	{"tree_bypath", 2, git_engine_tree_bypath, 0},
	{"tree_byid", 2, git_engine_tree_byid, 0},
	{"tree_nth", 2, git_engine_tree_nth, 0},
	{"tree_count", 1, git_engine_tree_count, 0},
	{"blob_size", 1, git_engine_blob_size, 0},
	{"blob_content", 1, git_engine_blob_content, 0},
	{"tag_list", 1, git_engine_tag_list, 0},
	{"tag_peel", 1, git_engine_tag_peel, 0},
	{"tag_name", 1, git_engine_tag_name, 0},
	{"tag_message", 1, git_engine_tag_message, 0},
	{"tag_author", 1, git_engine_tag_author, 0},
	{"library_version", 0, git_engine_library_version, 0},
	{"revwalk_new",  1, git_engine_revwalk_new, 0},
	{"revwalk_push", 3, git_engine_revwalk_push, 0},
	{"revwalk_next", 1, git_engine_revwalk_next, 0},
	{"revwalk_sorting", 2, git_engine_revwalk_sorting, 0},
	{"revwalk_simplify_first_parent", 1, git_engine_revwalk_simplify_first_parent, 0},
	{"revwalk_reset", 1,   git_engine_revwalk_reset, 0},
	{"revwalk_repository", 1, git_engine_revwalk_repository, 0},
	{"revwalk_pack", 1, git_engine_revwalk_pack, 0},
	{"pathspec_match_tree", 2, git_engine_pathspec_match_tree, 0},
	{"diff_tree", 4, git_engine_diff_tree, 0},
	{"diff_stats", 1, git_engine_diff_stats, 0},
	{"diff_delta_count", 1, git_engine_diff_delta_count, 0},
	{"diff_deltas", 1, git_engine_diff_deltas, 0},
	{"diff_format", 2, git_engine_diff_format, 0},
	{"index_new", 0, git_engine_index_new, 0},
	{"index_read_tree", 2, git_engine_index_read_tree, 0},
	{"index_write", 1, git_engine_index_write, 0},
	{"index_write_tree", 1, git_engine_index_write_tree, 0},
	{"index_write_tree", 2, git_engine_index_write_tree, 0},
	{"index_add", 2, git_engine_index_add, 0},
	{"index_remove", 3, git_engine_index_remove, 0},
	{"index_remove_dir", 3, git_engine_index_remove_dir, 0},
	{"index_count", 1, git_engine_index_count, 0},
	{"index_bypath", 3, git_engine_index_get, 0},
	{"index_nth", 2, git_engine_index_nth, 0},
	{"index_clear", 1, git_engine_index_clear, 0},
	{"signature_default", 1, git_engine_signature_default, 0},
	{"revparse_single", 2, git_engine_revparse_single, 0},
	{"revparse_ext", 2, git_engine_revparse_ext, 0},
	{"config_set_bool", 3, git_engine_config_set_bool, 0},
	{"config_get_bool", 2, git_engine_config_get_bool, 0},
	{"config_set_string", 3, git_engine_config_set_string, 0},
	{"config_get_string", 2, git_engine_config_get_string, 0},
	{"config_open", 1, git_engine_config_open, 0},
	{"pack_new", 1, git_engine_pack_new, 0},
	{"pack_insert_commit", 2, git_engine_pack_insert_commit, 0},
	{"pack_insert_walk", 2, git_engine_pack_insert_walk, 0},
	{"pack_data", 1, git_engine_pack_data, 0},
	{"worktree_add", 4, git_engine_worktree_add, 0},
	{"worktree_prune", 1, git_engine_worktree_prune, 0},
	{"merge_commits", 3, git_engine_merge_commits, 0},
	{"merge_base", 3, git_engine_merge_base, 0},
	{"blame_file", 3, git_engine_blame_file, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(Elixir.ExGitEngine.Git, git_engine_funcs, load, NULL, upgrade, unload)
