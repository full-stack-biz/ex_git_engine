#include "ex_git_engine.h"

#ifndef GIT_ENGINE_SIGNATURE_H
#define GIT_ENGINE_SIGNATURE_H

ERL_NIF_TERM git_engine_signature_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_signature_default(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

int git_engine_signature_from_erl(git_signature **out, ErlNifEnv *env, ERL_NIF_TERM *err, ERL_NIF_TERM term);
int git_engine_signature_to_erl(ERL_NIF_TERM *out_name, ERL_NIF_TERM *out_email, ERL_NIF_TERM *out_time, ERL_NIF_TERM *out_offset, ErlNifEnv *env, const git_signature *sig);

#endif
