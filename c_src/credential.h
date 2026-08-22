#ifndef GIT_ENGINE_CREDENTIAL_H
#define GIT_ENGINE_CREDENTIAL_H

#include "erl_nif.h"
#include <git2.h>

extern ErlNifResourceType *git_engine_credential_type;

typedef struct {
    ErlNifMutex *mtx;
    ErlNifCond  *cond;
    int          result_set;
    int          success;
    char        *username;
    char        *password;
} git_engine_credential_res;

typedef struct {
    ErlNifEnv           *env;
    ErlNifPid            runner_pid;
    git_engine_credential_res *res;
    ERL_NIF_TERM         res_term;
} git_engine_credential_payload;

void git_engine_credential_free(ErlNifEnv *env, void *obj);

int git_engine_credential_acquire_cb(
    git_credential **cred,
    const char *url,
    const char *username_from_url,
    unsigned int allowed_types,
    void *payload);

ERL_NIF_TERM git_engine_credential_deliver(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

#endif
