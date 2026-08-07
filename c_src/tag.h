#ifndef GIT_ENGINE_TAG_H
#define GIT_ENGINE_TAG_H

ERL_NIF_TERM git_engine_tag_list(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_tag_peel(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_tag_name(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_tag_message(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_tag_author(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

#endif
