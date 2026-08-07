#ifndef GIT_ENGINE_WORKTREE_H
#define GIT_ENGINE_WORKTREE_H

#include "erl_nif.h"
#include <git2.h>
#include "repository.h"

extern ErlNifResourceType *git_engine_worktree_type;

typedef struct {
	git_worktree *worktree;
	git_engine_repository *repo;
} git_engine_worktree;

void git_engine_worktree_free(ErlNifEnv *env, void *cd);

ERL_NIF_TERM git_engine_worktree_add(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_worktree_prune(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

#endif
