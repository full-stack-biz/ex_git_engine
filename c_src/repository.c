#include "repository.h"
#include "credential.h"
#include "object.h"
#include "odb.h"
#include "oid.h"
#include "config.h"
#include "index.h"
#include "ex_git_engine.h"
#include <string.h>
#include <stdlib.h>
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

static int git_engine_ssh_credential_cb(git_credential **, const char *, const char *, unsigned int, void *);
static int git_engine_ssh_cert_check_cb(git_cert *, int, const char *, void *);

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
	git_engine_credential_res *cred_res = NULL;
	git_engine_credential_payload cred_payload;

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

	/* argv[3]: static headers (non-auth) */
	headers = git_strarray_from_list(env, argv[3]);
	opts.fetch_opts.custom_headers = headers;

	/* argv[4]: PID = HTTP runner, binary = SSH key PEM, else = no auth */
	ErlNifBinary ssh_key_bin;
	char *ssh_private_key = NULL;

	if (enif_get_local_pid(env, argv[4], &cred_payload.runner_pid)) {
		cred_res = enif_alloc_resource(git_engine_credential_type,
		                               sizeof(git_engine_credential_res));
		memset(cred_res, 0, sizeof(git_engine_credential_res));
		cred_res->mtx = enif_mutex_create((char *)"credential_mtx");
		cred_res->cond = enif_cond_create((char *)"credential_cond");

		cred_payload.env      = env;
		cred_payload.res      = cred_res;
		cred_payload.res_term = enif_make_resource(env, cred_res);

		opts.fetch_opts.callbacks.credentials = git_engine_credential_acquire_cb;
		opts.fetch_opts.callbacks.payload     = &cred_payload;
	} else if (enif_inspect_binary(env, argv[4], &ssh_key_bin)) {
		ssh_private_key = malloc(ssh_key_bin.size + 1);
		if (!ssh_private_key) { git_strarray_free(&headers); return git_engine_oom(env); }
		memcpy(ssh_private_key, ssh_key_bin.data, ssh_key_bin.size);
		ssh_private_key[ssh_key_bin.size] = '\0';

		opts.fetch_opts.callbacks.credentials       = git_engine_ssh_credential_cb;
		opts.fetch_opts.callbacks.certificate_check = git_engine_ssh_cert_check_cb;
		opts.fetch_opts.callbacks.payload           = ssh_private_key;
	}

	error = git_clone(&repo, (char *)url.data, (char *)local_path.data, &opts);
	git_strarray_free(&headers);
	if (cred_res) enif_release_resource(cred_res);
	if (ssh_private_key) free(ssh_private_key);
	if (error < 0)
		return git_engine_error_struct(env, error);

	res_repo = enif_alloc_resource(git_engine_repository_type, sizeof(git_engine_repository));
	res_repo->repo = repo;
	term_repo = enif_make_resource(env, res_repo);
	enif_release_resource(res_repo);

	return enif_make_tuple2(env, atoms.ok, term_repo);
}

static int
git_engine_ssh_credential_cb(
    git_credential **cred,
    const char *url,
    const char *username_from_url,
    unsigned int allowed_types,
    void *payload)
{
    (void)url;
    if (!(allowed_types & GIT_CREDENTIAL_SSH_KEY) || !username_from_url)
        return GIT_PASSTHROUGH;
    return git_credential_ssh_key_memory_new(cred, username_from_url, NULL, (const char *)payload, "");
}

static int
git_engine_ssh_cert_check_cb(git_cert *cert, int valid, const char *host, void *payload)
{
    (void)cert; (void)valid; (void)host; (void)payload;
    /* ponytail: accept any host key; add fingerprint check if needed */
    return 0;
}

ERL_NIF_TERM
git_engine_repository_fetch(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int error;
	git_repository *repo = NULL;
	git_remote *remote = NULL;
	ErlNifBinary repo_path, remote_url;
	git_strarray refspecs = { NULL, 0 };
	git_fetch_options fetch_opts = GIT_FETCH_OPTIONS_INIT;
	git_engine_credential_res *cred_res = NULL;
	git_engine_credential_payload cred_payload;
	ErlNifBinary ssh_key_bin;
	char *ssh_private_key = NULL;

	if (!enif_inspect_binary(env, argv[0], &repo_path))
		return enif_make_badarg(env);
	if (!git_engine_terminate_binary(&repo_path))
		return git_engine_oom(env);

	if (!enif_inspect_binary(env, argv[1], &remote_url))
		return enif_make_badarg(env);
	if (!git_engine_terminate_binary(&remote_url))
		return git_engine_oom(env);

	refspecs = git_strarray_from_list(env, argv[2]);

	/* argv[3]: PID = HTTP runner, binary = SSH key PEM, else = no auth */
	if (enif_get_local_pid(env, argv[3], &cred_payload.runner_pid)) {
		cred_res = enif_alloc_resource(git_engine_credential_type,
		                               sizeof(git_engine_credential_res));
		memset(cred_res, 0, sizeof(git_engine_credential_res));
		cred_res->mtx = enif_mutex_create((char *)"credential_mtx");
		cred_res->cond = enif_cond_create((char *)"credential_cond");

		cred_payload.env      = env;
		cred_payload.res      = cred_res;
		cred_payload.res_term = enif_make_resource(env, cred_res);

		fetch_opts.callbacks.credentials = git_engine_credential_acquire_cb;
		fetch_opts.callbacks.payload     = &cred_payload;
	} else if (enif_inspect_binary(env, argv[3], &ssh_key_bin)) {
		ssh_private_key = malloc(ssh_key_bin.size + 1);
		if (!ssh_private_key) { git_strarray_free(&refspecs); return git_engine_oom(env); }
		memcpy(ssh_private_key, ssh_key_bin.data, ssh_key_bin.size);
		ssh_private_key[ssh_key_bin.size] = '\0';

		fetch_opts.callbacks.credentials       = git_engine_ssh_credential_cb;
		fetch_opts.callbacks.certificate_check = git_engine_ssh_cert_check_cb;
		fetch_opts.callbacks.payload           = ssh_private_key;
	}

	error = git_repository_open(&repo, (char *)repo_path.data);
	if (error < 0) goto done;

	error = git_remote_create_anonymous(&remote, repo, (char *)remote_url.data);
	if (error < 0) goto done;

	error = git_remote_fetch(remote, &refspecs, &fetch_opts, "fetch");

done:
	if (remote) git_remote_free(remote);
	if (repo) git_repository_free(repo);
	if (cred_res) enif_release_resource(cred_res);
	if (ssh_private_key) free(ssh_private_key);
	git_strarray_free(&refspecs);

	if (error < 0)
		return git_engine_error_struct(env, error);

	return atoms.ok;
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