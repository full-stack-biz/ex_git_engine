#include <git2.h>
#include <string.h>

#include "ex_git_engine.h"
#include "oid.h"

int git_engine_oid_bin(ErlNifBinary *bin, const git_oid *id, git_oid_t oid_type)
{
	size_t sz = git_engine_oid_rawsz(oid_type);
	if (!enif_alloc_binary(sz, bin))
		return -1;
	memcpy(bin->data, id->id, sz);
	return 0;
}

ERL_NIF_TERM
git_engine_oid_fmt(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifBinary bin, bin_out;
	git_oid id;
	git_oid_t oid_type;

	if (!enif_inspect_binary(env, argv[0], &bin))
		return enif_make_badarg(env);

	oid_type = git_engine_infer_oid_type(bin.size);
	if (bin.size != git_engine_oid_rawsz(oid_type))
		return enif_make_badarg(env);

	if (!enif_alloc_binary(git_engine_oid_hexsz(oid_type), &bin_out))
		return git_engine_oom(env);

	GIT_ENGINE_OID_FROMRAW(&id, bin.data, bin.size);
	git_oid_fmt((char *)bin_out.data, &id);

	return enif_make_binary(env, &bin_out);
}

ERL_NIF_TERM
git_engine_oid_parse(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifBinary bin, bin_out;
	git_oid id;
	git_oid_t oid_type;

	if (!enif_inspect_binary(env, argv[0], &bin))
		return enif_make_badarg(env);

	oid_type = git_engine_infer_oid_type(bin.size / 2);

	GIT_ENGINE_OID_FROMSTRN(&id, (const char *)bin.data, bin.size);

	if (git_engine_oid_bin(&bin_out, &id, oid_type) < 0)
		return git_engine_oom(env);

	return enif_make_binary(env, &bin_out);
}
