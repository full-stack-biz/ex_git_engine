#include <git2.h>
#include <string.h>

#include "ex_git_engine.h"
#include "object.h"
#include "blob.h"

ERL_NIF_TERM
git_engine_blob_size(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	git_engine_object *obj;
	const git_blob *blob;

	if (!enif_get_resource(env, argv[0], git_engine_object_type, (void **) &obj))
		return enif_make_badarg(env);

	blob = (git_blob *)obj->obj;

	return enif_make_tuple2(env, atoms.ok, enif_make_uint64(env, git_blob_rawsize(blob)));
}

ERL_NIF_TERM
git_engine_blob_content(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	git_engine_object *obj;
	const git_blob *blob;
	ErlNifBinary bin;
	size_t len;
	const void *content;

	if (!enif_get_resource(env, argv[0], git_engine_object_type, (void **) &obj))
		return enif_make_badarg(env);

	blob = (git_blob *)obj->obj;

	len = git_blob_rawsize(blob);
	content = git_blob_rawcontent(blob);
	if (!content)
		return atoms.error;

	if (!enif_alloc_binary(len, &bin))
		return git_engine_oom(env);

	memcpy(bin.data, content, len);

	return enif_make_tuple2(env, atoms.ok, enif_make_binary(env, &bin));
}
