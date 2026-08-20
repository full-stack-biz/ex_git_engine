#include "ex_git_engine.h"
#include "repository.h"
#include "object.h"
#include "oid.h"
#include "signature.h"
#include <string.h>
#include <git2.h>
#include <git2/sys/commit.h>

ERL_NIF_TERM
git_engine_commit_parent_count(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	git_engine_object *obj;

	if (!enif_get_resource(env, argv[0], git_engine_object_type, (void **) &obj))
		return enif_make_badarg(env);

	return enif_make_tuple2(env, atoms.ok, enif_make_uint64(env, git_commit_parentcount((git_commit *) obj->obj)));
}

ERL_NIF_TERM
git_engine_commit_parent(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int error;
	ErlNifBinary bin;
	git_engine_object *obj, *parent;
	ERL_NIF_TERM term_parent;
	unsigned int nth;

	if (!enif_get_resource(env, argv[0], git_engine_object_type, (void **) &obj))
		return enif_make_badarg(env);

	if (!enif_get_uint(env, argv[1], &nth))
		return enif_make_badarg(env);

	parent = enif_alloc_resource(git_engine_object_type, sizeof(git_engine_object));

	error = git_commit_parent((git_commit **) &parent->obj, (git_commit *) obj->obj, nth);
	if (error < 0)
		return git_engine_error_struct(env, error);

	term_parent = enif_make_resource(env, parent);
	enif_release_resource(parent);

	if (git_engine_oid_bin(&bin, git_object_id(parent->obj)) < 0)
		return git_engine_oom(env);

	parent->repo = obj->repo;
	enif_keep_resource(parent->repo);

	return enif_make_tuple3(env, atoms.ok, enif_make_binary(env, &bin), term_parent);
}

ERL_NIF_TERM
git_engine_commit_tree_id(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	const git_oid *id;
	git_engine_object *obj;
	ErlNifBinary bin;

	if (!enif_get_resource(env, argv[0], git_engine_object_type, (void **) &obj))
		return enif_make_badarg(env);

	id = git_commit_tree_id((git_commit *) obj->obj);

	if (git_engine_oid_bin(&bin, id) < 0)
		return git_engine_oom(env);

	return enif_make_binary(env, &bin);
}

ERL_NIF_TERM
git_engine_commit_tree(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int error;
	ErlNifBinary bin;
	git_engine_object *obj, *tree;
	ERL_NIF_TERM term_tree;

	if (!enif_get_resource(env, argv[0], git_engine_object_type, (void **) &obj))
		return enif_make_badarg(env);

	tree = enif_alloc_resource(git_engine_object_type, sizeof(git_engine_object));

	error = git_commit_tree((git_tree **) &tree->obj, (git_commit *) obj->obj);
	if (error < 0)
		return git_engine_error_struct(env, error);

	term_tree = enif_make_resource(env, tree);
	enif_release_resource(tree);

	if (git_engine_oid_bin(&bin, git_object_id(tree->obj)) < 0)
		return git_engine_oom(env);

	tree->repo = obj->repo;
	enif_keep_resource(tree->repo);

	return enif_make_tuple3(env, atoms.ok, enif_make_binary(env, &bin), term_tree);
}

ERL_NIF_TERM
git_engine_commit_create(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int error;
	git_engine_repository *repo;
	ErlNifBinary bin;
	char *ref = NULL, *encoding = NULL, *message = NULL;
	git_signature *author = NULL, *committer = NULL;
	ERL_NIF_TERM err, head, tail;
	unsigned int parents_len, i;
	git_oid tree, *parents_ids, commit_id;
	const git_oid **parents_ids_ptrs;

	if (!enif_get_resource(env, argv[0], git_engine_repository_type, (void **) &repo))
		return enif_make_badarg(env);

	if (enif_compare(argv[1], atoms.undefined)) {
		if (!enif_inspect_binary(env, argv[1], &bin))
		     return enif_make_badarg(env);
		ref = strndup((char *)bin.data, bin.size);
		if (ref == NULL)
			return git_engine_oom(env);
	}

	if (git_engine_signature_from_erl(&author, env, &err, argv[2]) < 0)
		return err;

	if (git_engine_signature_from_erl(&committer, env, &err, argv[3]) < 0) {
		git_signature_free(author);
		return err;
	}


	if (enif_compare(argv[4], atoms.undefined)) {
		if (!enif_inspect_binary(env, argv[4], &bin))
		     return enif_make_badarg(env);
		encoding = strndup((char *)bin.data, bin.size);
		if (encoding == NULL)
			return git_engine_oom(env);
	}

	if (!enif_inspect_binary(env, argv[5], &bin))
		return enif_make_badarg(env);

	message = strndup((char *)bin.data, bin.size);
	if (message == NULL)
		return git_engine_oom(env);

	if (!enif_inspect_binary(env, argv[6], &bin))
		return enif_make_badarg(env);
	if (bin.size != GIT_OID_RAWSZ)
		return enif_make_badarg(env);

	git_oid_fromraw(&tree, bin.data);

	if (!enif_get_list_length(env, argv[7], &parents_len))
		return enif_make_badarg(env);

	parents_ids = calloc(parents_len, sizeof(git_oid));
	if (parents_ids == NULL)
		return git_engine_oom(env);

	parents_ids_ptrs = calloc(parents_len, sizeof(git_oid *));
	if (parents_ids_ptrs == NULL)
		return git_engine_oom(env);

	i = 0;
	tail = argv[7];
	while (enif_get_list_cell(env, tail, &head, &tail)) {
		if (!enif_inspect_binary(env, head, &bin))
			return enif_make_badarg(env);
		if (bin.size != GIT_OID_RAWSZ)
			return enif_make_badarg(env);

		git_oid_fromraw(&parents_ids[i], bin.data);
		parents_ids_ptrs[i] = &parents_ids[i];
		i++;
	}

	error = git_commit_create_from_ids(&commit_id, repo->repo, ref, author, committer, encoding, message, &tree, parents_len, parents_ids_ptrs);
	if (error < 0)
		return git_engine_error_struct(env, error);

	if (!enif_realloc_binary(&bin, GIT_OID_RAWSZ))
		return git_engine_oom(env);

	memcpy(bin.data, &commit_id, GIT_OID_RAWSZ);

	return enif_make_tuple2(env, atoms.ok, enif_make_binary(env, &bin));
}

ERL_NIF_TERM
git_engine_commit_message(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifBinary bin;
	git_engine_object *obj;
	const char *msg;

	if (!enif_get_resource(env, argv[0], git_engine_object_type, (void **) &obj))
		return enif_make_badarg(env);

	msg = git_commit_message((git_commit *) obj->obj);
	if (git_engine_string_to_bin(&bin, msg) < 0)
		return git_engine_oom(env);

	return enif_make_tuple2(env, atoms.ok, enif_make_binary(env, &bin));
}

ERL_NIF_TERM
git_engine_commit_author(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ERL_NIF_TERM name, email, time, offset;
	git_engine_object *obj;
	const git_signature* signature;

	if (!enif_get_resource(env, argv[0], git_engine_object_type, (void **) &obj))
		return enif_make_badarg(env);

	signature = git_commit_author((git_commit *) obj->obj);
    if (signature == NULL)
        return git_engine_error(env);

    if (git_engine_signature_to_erl(&name, &email, &time, &offset, env, signature))
        return git_engine_error(env);

    return enif_make_tuple5(env, atoms.ok, name, email, time, offset);
}

ERL_NIF_TERM
git_engine_commit_committer(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ERL_NIF_TERM name, email, time, offset;
	git_engine_object *obj;
	const git_signature* signature;

	if (!enif_get_resource(env, argv[0], git_engine_object_type, (void **) &obj))
		return enif_make_badarg(env);

	signature = git_commit_committer((git_commit *) obj->obj);
    if (signature == NULL)
        return git_engine_error(env);

    if (git_engine_signature_to_erl(&name, &email, &time, &offset, env, signature))
        return git_engine_error(env);

    return enif_make_tuple5(env, atoms.ok, name, email, time, offset);
}

ERL_NIF_TERM
git_engine_commit_time(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ERL_NIF_TERM time, offset;
	git_engine_object *obj;

	if (!enif_get_resource(env, argv[0], git_engine_object_type, (void **) &obj))
		return enif_make_badarg(env);

	time = enif_make_ulong(env, git_commit_time((git_commit *) obj->obj));
	offset = enif_make_uint(env, git_commit_time_offset((git_commit *) obj->obj));

    return enif_make_tuple3(env, atoms.ok, time, offset);
}

ERL_NIF_TERM
git_engine_commit_raw_header(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifBinary bin;
	git_engine_object *obj;
    char *raw_header;

	if (!enif_get_resource(env, argv[0], git_engine_object_type, (void **) &obj))
		return enif_make_badarg(env);

	raw_header = git_commit_raw_header((git_commit *) obj->obj);
	if (git_engine_string_to_bin(&bin, raw_header) < 0)
		return git_engine_oom(env);

	return enif_make_tuple2(env, atoms.ok, enif_make_binary(env, &bin));
}

ERL_NIF_TERM
git_engine_commit_raw(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int error;
	git_buf signature = { NULL, 0, 0 };
	git_buf signed_data = { NULL, 0, 0 };
	ErlNifBinary bin;
	git_engine_object *obj;
	git_oid oid;

	if (!enif_get_resource(env, argv[0], git_engine_object_type, (void **) &obj))
		return enif_make_badarg(env);

	git_oid_cpy(&oid, git_object_id(obj->obj));

	error = git_commit_extract_signature(&signature, &signed_data, obj->repo->repo, &oid, NULL);
	if (error < 0) {
		git_buf_free(&signature);
		git_buf_free(&signed_data);
		return git_engine_error_struct(env, error);
	}

	if (!enif_alloc_binary(signed_data.size, &bin)) {
		git_buf_free(&signature);
		git_buf_free(&signed_data);
		return git_engine_oom(env);
	}

	memcpy(bin.data, signed_data.ptr, signed_data.size);
	git_buf_free(&signature);
	git_buf_free(&signed_data);

	return enif_make_tuple2(env, atoms.ok, enif_make_binary(env, &bin));
}

ERL_NIF_TERM
git_engine_commit_header(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int error;
	git_buf buf = { NULL, 0, 0 };
	ErlNifBinary bin;
	git_engine_object *obj;

	if (!enif_get_resource(env, argv[0], git_engine_object_type, (void **) &obj))
		return enif_make_badarg(env);

	if (!enif_inspect_binary(env, argv[1], &bin))
		return enif_make_badarg(env);

	if (!git_engine_terminate_binary(&bin))
        return git_engine_oom(env);

	error = git_commit_header_field(&buf, (git_commit *) obj->obj, (char *) bin.data);
	if (error < 0) {
		return git_engine_error_struct(env, error);
	}

	if (!enif_alloc_binary(buf.size, &bin)) {
		git_buf_free(&buf);
		return git_engine_oom(env);
	}

	memcpy(bin.data, buf.ptr, bin.size);
	git_buf_free(&buf);

	return enif_make_tuple2(env, atoms.ok, enif_make_binary(env, &bin));
}
