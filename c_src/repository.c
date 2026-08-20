#include "repository.h"
#include "object.h"
#include "odb.h"
#include "oid.h"
#include "config.h"
#include "index.h"
#include "ex_git_engine.h"
#include <string.h>
#include <git2.h>

void git_engine_repository_free(ErlNifEnv *env, void *cd)
{
	git_engine_repository *grepo = (git_engine_repository *)cd;
	git_repository_free(grepo->repo);
}

ERL_NIF_TERM
git_engine_repository_init(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int bare, error;
	git_repository *repo;
	git_engine_repository *res_repo;
	ErlNifBinary bin, head;
	ERL_NIF_TERM term_repo;

	if (!enif_inspect_binary(env, argv[0], &bin))
		return enif_make_badarg(env);

	if (!git_engine_terminate_binary(&bin))
		return git_engine_oom(env);

	git_repository_init_options options = GIT_REPOSITORY_INIT_OPTIONS_INIT;
	options.flags = GIT_REPOSITORY_INIT_MKPATH;

	bare = !enif_compare(argv[1], atoms.true);
	if (bare) {
		options.flags |= GIT_REPOSITORY_INIT_BARE;
	}

	if (!enif_inspect_binary(env, argv[2], &head))
		return enif_make_badarg(env);

	if (!git_engine_terminate_binary(&head))
		return git_engine_oom(env);

	options.initial_head = (char *)head.data;

	error = git_repository_init_ext(&repo, (char *)bin.data, &options);
	if (error < 0)
		return git_engine_error_struct(env, error);

	res_repo = enif_alloc_resource(git_engine_repository_type, sizeof(git_engine_repository));
	res_repo->repo = repo;
	term_repo = enif_make_resource(env, res_repo);
	enif_release_resource(res_repo);

	return enif_make_tuple2(env, atoms.ok, term_repo);
}

ERL_NIF_TERM
git_engine_repository_open(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int error;
	git_repository *repo;
	git_engine_repository *res_repo;
	ErlNifBinary bin;
	ERL_NIF_TERM term_repo;

	if (!enif_inspect_binary(env, argv[0], &bin))
		return enif_make_badarg(env);

	if (!git_engine_terminate_binary(&bin))
		return git_engine_oom(env);

	error = git_repository_open(&repo, (char *)bin.data);
	if (error < 0)
		return git_engine_error_struct(env, error);

	res_repo = enif_alloc_resource(git_engine_repository_type, sizeof(git_engine_repository));
	res_repo->repo = repo;
	term_repo = enif_make_resource(env, res_repo);
	enif_release_resource(res_repo);

	return enif_make_tuple2(env, atoms.ok, term_repo);
}

ERL_NIF_TERM
git_engine_repository_discover(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	git_buf buf = {NULL, 0, 0};
	ErlNifBinary bin, path;
	int error;

	if (!enif_inspect_binary(env, argv[0], &bin))
		return enif_make_badarg(env);

	if (!git_engine_terminate_binary(&bin))
		return git_engine_oom(env);

	error = git_repository_discover(&buf, (char *)bin.data, 0, NULL);
	enif_release_binary(&bin);
	if (error < 0)
		return git_engine_error_struct(env, error);

	if (!enif_alloc_binary(strlen(buf.ptr), &path))
		return git_engine_oom(env);

	memcpy(path.data, buf.ptr, path.size);

	return enif_make_tuple2(env, atoms.ok, enif_make_binary(env, &path));
}

ERL_NIF_TERM
git_engine_repository_path(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	git_engine_repository *repo;
	const char *path;
	size_t len;
	ErlNifBinary bin;

	if (!enif_get_resource(env, argv[0], git_engine_repository_type, (void **)&repo))
		return enif_make_badarg(env);

	path = git_repository_path(repo->repo);
	len = strlen(path);

	if (!enif_alloc_binary(len, &bin))
		return git_engine_oom(env);

	memcpy(bin.data, path, len);
	return enif_make_binary(env, &bin);
}

ERL_NIF_TERM
git_engine_repository_workdir(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	git_engine_repository *repo;
	const char *path;
	size_t len;
	ErlNifBinary bin;

	if (!enif_get_resource(env, argv[0], git_engine_repository_type, (void **)&repo))
		return enif_make_badarg(env);

	if (git_repository_is_bare(repo->repo))
		return atoms.error;

	path = git_repository_workdir(repo->repo);
	len = strlen(path);

	if (!enif_alloc_binary(len, &bin))
		return git_engine_oom(env);

	memcpy(bin.data, path, len);
	return enif_make_binary(env, &bin);
}

ERL_NIF_TERM
git_engine_repository_is_bare(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	git_engine_repository *repo;
	int bare;

	if (!enif_get_resource(env, argv[0], git_engine_repository_type, (void **)&repo))
		return enif_make_badarg(env);

	bare = git_repository_is_bare(repo->repo);

	if (bare)
		return atoms.true;

	return atoms.false;
}

ERL_NIF_TERM
git_engine_repository_is_empty(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	git_engine_repository *repo;
	int empty;

	if (!enif_get_resource(env, argv[0], git_engine_repository_type, (void **)&repo))
		return enif_make_badarg(env);

	empty = git_repository_head_unborn(repo->repo);

	if (empty == 1)
		return atoms.true;

	return atoms.false;
}

ERL_NIF_TERM
git_engine_repository_config(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int error;
	git_engine_repository *repo;
	git_engine_config *cfg;
	ERL_NIF_TERM term_cfg;

	if (!enif_get_resource(env, argv[0], git_engine_repository_type, (void **)&repo))
		return enif_make_badarg(env);

	cfg = enif_alloc_resource(git_engine_config_type, sizeof(git_engine_config));
	error = git_repository_config(&cfg->config, repo->repo);
	if (error < 0)
		return git_engine_error_struct(env, error);

	term_cfg = enif_make_resource(env, cfg);
	enif_release_resource(cfg);

	return enif_make_tuple2(env, atoms.ok, term_cfg);
}

ERL_NIF_TERM
git_engine_repository_odb(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int error;
	git_engine_repository *repo;
	git_engine_odb *odb;
	ERL_NIF_TERM term_odb;

	if (!enif_get_resource(env, argv[0], git_engine_repository_type, (void **)&repo))
		return enif_make_badarg(env);

	odb = enif_alloc_resource(git_engine_odb_type, sizeof(git_engine_odb));
	error = git_repository_odb(&odb->odb, repo->repo);
	if (error < 0)
		return git_engine_error_struct(env, error);

	term_odb = enif_make_resource(env, odb);
	enif_release_resource(odb);

	return enif_make_tuple2(env, atoms.ok, term_odb);
}

ERL_NIF_TERM
git_engine_repository_clone(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int error, bare;
	git_repository *repo;
	git_engine_repository *res_repo;
	ErlNifBinary url, local_path;
	ERL_NIF_TERM term_repo;
	git_clone_options opts = GIT_CLONE_OPTIONS_INIT;
	git_strarray headers = { NULL, 0 };

	if (!enif_inspect_binary(env, argv[0], &url))
		return enif_make_badarg(env);

	if (!git_engine_terminate_binary(&url))
		return git_engine_oom(env);

	if (!enif_inspect_binary(env, argv[1], &local_path))
		return enif_make_badarg(env);

	if (!git_engine_terminate_binary(&local_path))
		return git_engine_oom(env);

	bare = !enif_compare(argv[2], atoms.true);
	opts.bare = bare ? 1 : 0;

	headers = git_strarray_from_list(env, argv[3]);
	opts.fetch_opts.custom_headers = headers;

	error = git_clone(&repo, (char *)url.data, (char *)local_path.data, &opts);
	git_strarray_free(&headers);
	if (error < 0)
		return git_engine_error_struct(env, error);

	res_repo = enif_alloc_resource(git_engine_repository_type, sizeof(git_engine_repository));
	res_repo->repo = repo;
	term_repo = enif_make_resource(env, res_repo);
	enif_release_resource(res_repo);

	return enif_make_tuple2(env, atoms.ok, term_repo);
}

ERL_NIF_TERM
git_engine_repository_index(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int error;
	git_engine_repository *repo;
	git_engine_index *index;
	ERL_NIF_TERM term_index;

	if (!enif_get_resource(env, argv[0], git_engine_repository_type, (void **)&repo))
		return enif_make_badarg(env);

	index = enif_alloc_resource(git_engine_index_type, sizeof(git_engine_index));
	error = git_repository_index(&index->index, repo->repo);
	if (error < 0)
		return git_engine_error_struct(env, error);

	term_index = enif_make_resource(env, index);
	enif_release_resource(index);

	return enif_make_tuple2(env, atoms.ok, term_index);
}