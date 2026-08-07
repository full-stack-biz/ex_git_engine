#include <git2.h>
#include <string.h>

#include "ex_git_engine.h"
#include "oid.h"

int git_engine_oid_bin(ErlNifBinary *bin, const git_oid *id)
{
	if (!enif_alloc_binary(GIT_OID_RAWSZ, bin))
		return -1;

	memcpy(bin->data, id, GIT_OID_RAWSZ);
	return 0;
}

ERL_NIF_TERM
git_engine_oid_fmt(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifBinary bin, bin_out;
	git_oid id;

	if (!enif_inspect_binary(env, argv[0], &bin))
		return enif_make_badarg(env);

	if (bin.size != GIT_OID_RAWSZ)
		return enif_make_badarg(env);

	if (!enif_alloc_binary(GIT_OID_HEXSZ, &bin_out))
		return git_engine_oom(env);

	git_oid_fromraw(&id, bin.data);
	git_oid_fmt((char *)bin_out.data, &id);

	return enif_make_binary(env, &bin_out);
}

ERL_NIF_TERM
git_engine_oid_parse(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifBinary bin, bin_out;
	git_oid id;

	if (!enif_inspect_binary(env, argv[0], &bin))
		return enif_make_badarg(env);

	git_oid_fromstrn(&id, (const char *)bin.data, bin.size);

	if (git_engine_oid_bin(&bin_out, &id) < 0)
		return git_engine_oom(env);

	return enif_make_binary(env, &bin_out);
}
