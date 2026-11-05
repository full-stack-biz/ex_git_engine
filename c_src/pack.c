#include "ex_git_engine.h"
#include "pack.h"
#include "repository.h"
#include "revwalk.h"
#include <stdio.h>
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

typedef struct {
	FILE *file;
	int failed;
} pack_file_sink;

static int pack_file_write(void *buf, size_t size, void *payload)
{
	pack_file_sink *sink = (pack_file_sink *) payload;

	if (fwrite(buf, 1, size, sink->file) == size)
		return 0;

	sink->failed = 1;
	return -1;
}

/*
 * Writes the pack to the existing file at `path` as libgit2 produces it, without holding it in
 * memory. "r+" rather than "w": a file its owner removed (the client left) is not created again.
 */
ERL_NIF_TERM
git_engine_pack_to_file(ErlNifEnv *env, git_packbuilder *pb, ERL_NIF_TERM path)
{
	ErlNifBinary path_bin;
	pack_file_sink sink = {NULL, 0};
	char *c_path;
	int error;

	if (!enif_inspect_binary(env, path, &path_bin))
		return enif_make_badarg(env);

	c_path = enif_alloc(path_bin.size + 1);
	if (!c_path)
		return git_engine_oom(env);

	memcpy(c_path, path_bin.data, path_bin.size);
	c_path[path_bin.size] = '\0';
	sink.file = fopen(c_path, "r+b");
	enif_free(c_path);

	if (!sink.file)
		return enif_make_tuple2(env, atoms.error, enif_make_atom(env, "pack_file_failed"));

	error = git_packbuilder_foreach(pb, pack_file_write, &sink);

	if (fclose(sink.file) != 0)
		sink.failed = 1;

	if (sink.failed)
		return enif_make_tuple2(env, atoms.error, enif_make_atom(env, "pack_file_failed"));

	if (error < 0)
		return git_engine_error_struct(env, error);

	return atoms.ok;
}

ERL_NIF_TERM
git_engine_pack_write_file(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	git_engine_pack *pack;

	if (!enif_get_resource(env, argv[0], git_engine_pack_type, (void **)&pack))
		return enif_make_badarg(env);

	return git_engine_pack_to_file(env, pack->pack, argv[1]);
}