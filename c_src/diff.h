#ifndef GIT_ENGINE_DIFF_H
#define GIT_ENGINE_DIFF_H

#include "erl_nif.h"
#include <git2.h>
#include "repository.h"

extern ErlNifResourceType *git_engine_diff_type;

typedef struct {
	git_diff *diff;
	git_engine_repository *repo;
} git_engine_diff;

extern ErlNifResourceType *git_engine_patch_type;

typedef struct {
	git_patch *patch;
	git_engine_diff *diff;
} git_engine_patch;

void git_engine_diff_free(ErlNifEnv *env, void *cd);
void git_engine_patch_free(ErlNifEnv *env, void *cd);

ERL_NIF_TERM git_engine_diff_tree(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_diff_stats(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_diff_delta_count(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_diff_deltas(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_diff_format(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_diff_files(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_diff_patch(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_patch_text(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

#endif

