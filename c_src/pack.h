#ifndef GIT_ENGINE_PACK_H
#define GIT_ENGINE_PACK_H

#include "erl_nif.h"
#include <git2.h>
#include "repository.h"

extern ErlNifResourceType *git_engine_pack_type;

typedef struct {
    git_packbuilder* pack;
	git_engine_repository *repo;
} git_engine_pack;

void git_engine_pack_free(ErlNifEnv *env, void *cd);

ERL_NIF_TERM git_engine_pack_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_pack_insert_commit(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_pack_insert_walk(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_pack_data(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

#endif
