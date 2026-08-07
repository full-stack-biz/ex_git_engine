#ifndef GIT_ENGINE_REVWALK_H
#define GIT_ENGINE_REVWALK_H

#include "erl_nif.h"
#include <git2.h>
#include "repository.h"

extern ErlNifResourceType *git_engine_revwalk_type;

typedef struct {
	git_revwalk *walk;
	git_engine_repository *repo;
} git_engine_revwalk;

void git_engine_revwalk_free(ErlNifEnv *env, void *cd);

ERL_NIF_TERM git_engine_revwalk_repository(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_revwalk_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_revwalk_next(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_revwalk_push(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_revwalk_sorting(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_revwalk_simplify_first_parent(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_revwalk_reset(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_revwalk_pack(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

#endif
