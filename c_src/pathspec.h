#ifndef GIT_ENGINE_PATHSPEC_H
#define GIT_ENGINE_PATHSPEC_H

#include "object.h"

ERL_NIF_TERM git_engine_pathspec_match_tree(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

#endif

