#ifndef GIT_ENGINE_REFERENCE_H
#define GIT_ENGINE_REFERENCE_H

#include "erl_nif.h"
#include <git2.h>

extern ErlNifResourceType *git_engine_ref_iter_type;

typedef struct {
	git_reference_iterator *iter;
	git_engine_repository *repo;
} git_engine_ref_iter;

ERL_NIF_TERM git_engine_reference_list(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_reference_peel(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_reference_to_id(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_reference_glob(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_reference_lookup(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_reference_resolve(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_reference_create(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_reference_delete(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_reference_dwim(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_reference_iterator(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_reference_next(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_reference_has_log(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

void git_engine_ref_iter_free(ErlNifEnv *env, void *cd);

#endif
