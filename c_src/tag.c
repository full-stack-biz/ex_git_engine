#include <git2.h>
#include <string.h>
#include <stdio.h>

#include "oid.h"
#include "ex_git_engine.h"
#include "signature.h"
#include "tree.h"

ERL_NIF_TERM
git_engine_tag_list(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int error;
	size_t i;
	git_strarray array;
	git_engine_repository *repo;
	ERL_NIF_TERM list;

	if (!enif_get_resource(env, argv[0], git_engine_repository_type, (void **) &repo))
		return enif_make_badarg(env);

	error = git_tag_list(&array, repo->repo);
	if (error < 0)
		return git_engine_error_struct(env, error);

	list = enif_make_list(env, 0);
	for (i = 0; i < array.count; i++) {
		ErlNifBinary bin;
		size_t len = strlen(array.strings[i]);

		if (!enif_alloc_binary(len, &bin))
			goto on_error;

		memcpy(bin.data, array.strings[i], len);
		list = enif_make_list_cell(env, enif_make_binary(env, &bin), list);
	}

	git_strarray_free(&array);

	return enif_make_tuple2(env, atoms.ok, list);

on_error:
	git_strarray_free(&array);
	return git_engine_oom(env);
}

ERL_NIF_TERM
git_engine_tag_peel(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int error;
	git_engine_object *obj, *peeled;
	ERL_NIF_TERM term_peeled;
	ErlNifBinary id;

	if (!enif_get_resource(env, argv[0], git_engine_object_type, (void **) &obj))
		return enif_make_badarg(env);

	if (git_object_type(obj->obj) != GIT_OBJ_TAG)
		return enif_make_badarg(env);

	peeled = enif_alloc_resource(git_engine_object_type, sizeof(git_engine_object));
	if (!peeled)
		return git_engine_oom(env);

	error = git_tag_peel(&peeled->obj, (git_tag *)obj->obj);
	if (error < 0)
		return git_engine_error_struct(env, error);

	if(git_engine_oid_bin(&id, git_object_id(peeled->obj)) < 0) {
		enif_release_resource(peeled);
		git_object_free(obj->obj);
		return git_engine_oom(env);
	}

	peeled->repo = obj->repo;
	enif_keep_resource(peeled->repo);

	term_peeled = enif_make_resource(env, peeled);
	enif_release_resource(peeled);

	return enif_make_tuple4(env, atoms.ok, git_engine_object_type2atom(git_object_type(peeled->obj)),
				enif_make_binary(env, &id), term_peeled);
}

ERL_NIF_TERM
git_engine_tag_name(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	git_engine_object *obj;
	ErlNifBinary bin;
    const char *name;

	if (!enif_get_resource(env, argv[0], git_engine_object_type, (void **) &obj))
		return enif_make_badarg(env);

	name = git_tag_name((git_tag *) obj->obj);
	if (git_engine_string_to_bin(&bin, name) < 0)
		return git_engine_oom(env);

	return enif_make_tuple2(env, atoms.ok, enif_make_binary(env, &bin));
}

ERL_NIF_TERM
git_engine_tag_message(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	git_engine_object *obj;
	ErlNifBinary bin;
    const char *msg;

	if (!enif_get_resource(env, argv[0], git_engine_object_type, (void **) &obj))
		return enif_make_badarg(env);

	msg = git_tag_message((git_tag *) obj->obj);
	if (git_engine_string_to_bin(&bin, msg) < 0)
		return git_engine_oom(env);

	return enif_make_tuple2(env, atoms.ok, enif_make_binary(env, &bin));
}

ERL_NIF_TERM
git_engine_tag_author(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ERL_NIF_TERM name, email, time, offset;
	git_engine_object *obj;
	const git_signature *signature;

	if (!enif_get_resource(env, argv[0], git_engine_object_type, (void **) &obj))
		return enif_make_badarg(env);

	signature = git_tag_tagger((git_tag *) obj->obj);
    if (signature == NULL)
        return git_engine_error(env);

    if (git_engine_signature_to_erl(&name, &email, &time, &offset, env, signature))
        return git_engine_error(env);

    return enif_make_tuple5(env, atoms.ok, name, email, time, offset);
}
