#ifndef GIT_ENGINE_REPOSTIORY_H
#define GIT_ENGINE_REPOSTIORY_H

#include "erl_nif.h"
#include <git2.h>

#define MAXBUFLEN       1024

ERL_NIF_TERM git_engine_repository_init(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_repository_open(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_repository_discover(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_repository_path(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_repository_workdir(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_repository_is_bare(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_repository_is_empty(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_repository_odb(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_repository_index(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_repository_config(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_repository_clone(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

void git_engine_repository_free(ErlNifEnv *env, void *cd);

extern ErlNifResourceType *git_engine_repository_type;

typedef struct {
    git_repository *repo;
} git_engine_repository;

#endif
