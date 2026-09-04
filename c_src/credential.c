#include "credential.h"
#include "ex_git_engine.h"
#include <string.h>
#include <stdlib.h>

void git_engine_credential_free(ErlNifEnv *env, void *obj)
{
    git_engine_credential_res *res = (git_engine_credential_res *)obj;
    if (res->username) { free(res->username); res->username = NULL; }
    if (res->password) { free(res->password); res->password = NULL; }
    if (res->cond)  { enif_cond_destroy(res->cond);  res->cond  = NULL; }
    if (res->mtx)   { enif_mutex_destroy(res->mtx);  res->mtx   = NULL; }
}

int git_engine_credential_acquire_cb(
    git_credential **cred,
    const char *url,
    const char *username_from_url,
    unsigned int allowed_types,
    void *payload)
{
    if (!(allowed_types & GIT_CREDENTIAL_USERPASS_PLAINTEXT))
        return GIT_PASSTHROUGH;

    git_engine_credential_payload *cp = (git_engine_credential_payload *)payload;

    /* Build {:credential_request, res_term, url_binary} and send to runner. */
    ErlNifEnv *msg_env = enif_alloc_env();
    if (!msg_env) return GIT_PASSTHROUGH;

    size_t url_len = strlen(url);
    ErlNifBinary url_bin;
    if (!enif_alloc_binary(url_len, &url_bin)) {
        enif_free_env(msg_env);
        return GIT_PASSTHROUGH;
    }
    memcpy(url_bin.data, url, url_len);

    ERL_NIF_TERM msg = enif_make_tuple3(msg_env,
        enif_make_atom(msg_env, "credential_request"),
        enif_make_copy(msg_env, cp->res_term),
        enif_make_binary(msg_env, &url_bin));

    enif_send(cp->env, &cp->runner_pid, msg_env, msg);
    enif_free_env(msg_env);

    /* Block dirty-scheduler thread until runner delivers credentials. */
    enif_mutex_lock(cp->res->mtx);
    while (!cp->res->result_set)
        enif_cond_wait(cp->res->cond, cp->res->mtx);
    enif_mutex_unlock(cp->res->mtx);

    if (!cp->res->success)
        return GIT_PASSTHROUGH;

    int ret = git_credential_userpass_plaintext_new(cred, cp->res->username, cp->res->password);

    /* Reset for potential libgit2 retry. */
    enif_mutex_lock(cp->res->mtx);
    free(cp->res->username); cp->res->username = NULL;
    free(cp->res->password); cp->res->password = NULL;
    cp->res->result_set = 0;
    cp->res->success    = 0;
    enif_mutex_unlock(cp->res->mtx);

    return ret;
}

/* Called by the Elixir runner: credential_deliver(res_term, {:ok, {username, password}} | :error) */
ERL_NIF_TERM
git_engine_credential_deliver(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    git_engine_credential_res *res;
    if (!enif_get_resource(env, argv[0], git_engine_credential_type, (void **)&res))
        return enif_make_badarg(env);

    int arity;
    const ERL_NIF_TERM *tuple;
    ErlNifBinary username_bin, password_bin;

    enif_mutex_lock(res->mtx);

    if (enif_compare(argv[1], atoms.error) == 0) {
        res->success = 0;
    } else if (enif_get_tuple(env, argv[1], &arity, &tuple) && arity == 2
               && enif_compare(tuple[0], atoms.ok) == 0) {
        /* tuple[1] should be {username_binary, password_binary} */
        const ERL_NIF_TERM *cred;
        int cred_arity;
        if (enif_get_tuple(env, tuple[1], &cred_arity, &cred) && cred_arity == 2
            && enif_inspect_binary(env, cred[0], &username_bin)
            && enif_inspect_binary(env, cred[1], &password_bin)) {

            res->username = malloc(username_bin.size + 1);
            res->password = malloc(password_bin.size + 1);
            if (res->username && res->password) {
                memcpy(res->username, username_bin.data, username_bin.size);
                memcpy(res->password, password_bin.data, password_bin.size);
                res->username[username_bin.size] = '\0';
                res->password[password_bin.size] = '\0';
                res->success = 1;
            } else {
                free(res->username); res->username = NULL;
                free(res->password); res->password = NULL;
                res->success = 0;
            }
        } else {
            res->success = 0;
        }
    } else {
        res->success = 0;
    }

    res->result_set = 1;
    enif_cond_signal(res->cond);
    enif_mutex_unlock(res->mtx);

    return atoms.ok;
}
