#include "ex_git_engine.h"
#include "pack.h"
#include "repository.h"
#include "revwalk.h"
#include <string.h>
#include <git2.h>

void git_engine_pack_free(ErlNifEnv *env, void *pb)
{
	git_engine_pack *pack = (git_engine_pack *) pb;
	enif_release_resource(pack->repo);
	git_packbuilder_free(pack->pack);
}

ERL_NIF_TERM
git_engine_pack_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int error;
	git_engine_repository *repo;
	git_engine_pack *pack;
	ERL_NIF_TERM pack_term;

	if (!enif_get_resource(env, argv[0], git_engine_repository_type, (void **) &repo))
		return enif_make_badarg(env);

	pack = enif_alloc_resource(git_engine_pack_type, sizeof(git_engine_pack));
	if (!pack)
		return git_engine_oom(env);

	error = git_packbuilder_new(&pack->pack, repo->repo);
	if (error < 0) {
		enif_release_resource(pack);
		return git_engine_error_struct(env, error);
	}

	pack_term = enif_make_resource(env, pack);
	enif_release_resource(pack);
	pack->repo = repo;
	enif_keep_resource(repo);

	return enif_make_tuple2(env, atoms.ok, pack_term);
}

ERL_NIF_TERM
git_engine_pack_insert_commit(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int error;
	git_engine_pack *pack;
	ErlNifBinary bin;
	git_oid id;

	if (!enif_get_resource(env, argv[0], git_engine_pack_type, (void **)&pack))
		return enif_make_badarg(env);

	if (!enif_inspect_binary(env, argv[1], &bin))
		return enif_make_badarg(env);

	if (bin.size != GIT_OID_RAWSZ)
		return enif_make_badarg(env);

	git_oid_fromraw(&id, bin.data);

	error = git_packbuilder_insert_commit(pack->pack, &id);
	if (error < 0)
		return git_engine_error_struct(env, error);

	return atoms.ok;
}


ERL_NIF_TERM
git_engine_pack_insert_walk(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int error;
	git_engine_pack *pack;
	git_engine_revwalk *walk;

	if (!enif_get_resource(env, argv[0], git_engine_pack_type, (void **)&pack))
		return enif_make_badarg(env);

	if (!enif_get_resource(env, argv[1], git_engine_revwalk_type, (void **)&walk))
		return enif_make_badarg(env);

	error = git_packbuilder_insert_walk(pack->pack, walk->walk);
	if (error < 0)
		return git_engine_error_struct(env, error);

	return atoms.ok;
}

ERL_NIF_TERM
git_engine_pack_data(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int error;
	git_buf buf = {NULL, 0, 0};
	ErlNifBinary data;
	git_engine_pack *pack;

	if (!enif_get_resource(env, argv[0], git_engine_pack_type, (void **)&pack))
		return enif_make_badarg(env);

	error = git_packbuilder_write_buf(&buf, pack->pack);
	if (error < 0)
		return git_engine_error_struct(env, error);

	if (!enif_alloc_binary(buf.size, &data)) {
		git_buf_free(&buf);
		return git_engine_oom(env);
	}

	memcpy(data.data, buf.ptr, data.size);
	git_buf_free(&buf);

	return enif_make_tuple2(env, atoms.ok, enif_make_binary(env, &data));
}