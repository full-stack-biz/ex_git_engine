#ifndef GEEF_MERGE_H
#define GEEF_MERGE_H

#include "erl_nif.h"

ERL_NIF_TERM geef_merge_commits(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM geef_merge_base(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

#endif
