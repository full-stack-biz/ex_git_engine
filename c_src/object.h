#ifndef GIT_ENGINE_OBJECT_H
#define GIT_ENGINE_OBJECT_H

#include "erl_nif.h"
#include <git2.h>
#include "repository.h"

extern ErlNifResourceType *git_engine_object_type;

typedef struct {
	git_object *obj;
	git_engine_repository *repo;
} git_engine_object;

ERL_NIF_TERM git_engine_object_repository(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_object_lookup(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_object_id(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_object_zlib_inflate(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

ERL_NIF_TERM git_engine_object_type2atom(const git_otype type);

git_otype git_engine_object_atom2type(ERL_NIF_TERM term);
void git_engine_object_free(ErlNifEnv *env, void *cd);

#endif
