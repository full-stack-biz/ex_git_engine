#ifndef GIT_ENGINE_INDEX_H
#define GIT_ENGINE_INDEX_H

#include "erl_nif.h"
#include <git2.h>
#include "repository.h"

extern ErlNifResourceType *git_engine_index_type;

typedef struct {
	git_index *index;
} git_engine_index;

void git_engine_index_free(ErlNifEnv *env, void *cd);

ERL_NIF_TERM git_engine_index_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_index_write(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_index_write_tree(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_index_clear(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_index_read_tree(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_index_add(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_index_remove(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_index_remove_dir(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_index_count(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_index_nth(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_index_get(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

#endif
