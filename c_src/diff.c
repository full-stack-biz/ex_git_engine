#include <string.h>
#include <limits.h>
#include <locale.h>
#include <pthread.h>
#ifdef __APPLE__
#include <xlocale.h>
#endif
#include <git2.h>

#include "ex_git_engine.h"
#include "object.h"
#include "oid.h"
#include "diff.h"

static locale_t c_locale;
static pthread_once_t c_locale_once = PTHREAD_ONCE_INIT;

static void
diff_c_locale_init(void)
{
	c_locale = newlocale(LC_ALL_MASK, "C", (locale_t)0);
}

static locale_t
diff_c_locale(void)
{
	pthread_once(&c_locale_once, diff_c_locale_init);
	return c_locale;
}

typedef struct {
	ERL_NIF_TERM hunk;
	ERL_NIF_TERM lines;
} diff_hunk;

typedef struct {
	ERL_NIF_TERM delta;
	diff_hunk **hunks;
	size_t size;
} diff_delta;

typedef struct {
	ErlNifEnv *env;
	diff_delta **deltas;
	size_t size;
} diff_pack;

static git_diff_format_t diff_format_atom2type(ERL_NIF_TERM term)
{
	if (!enif_compare(term, atoms.format_patch))
		return GIT_DIFF_FORMAT_PATCH;
	else if (!enif_compare(term, atoms.format_patch_header))
		return GIT_DIFF_FORMAT_PATCH_HEADER;
	else if (!enif_compare(term, atoms.format_raw))
		return GIT_DIFF_FORMAT_RAW;
	else if (!enif_compare(term, atoms.format_name_only))
		return GIT_DIFF_FORMAT_NAME_ONLY;
	else if (!enif_compare(term, atoms.format_name_status))
		return GIT_DIFF_FORMAT_NAME_STATUS;

	return GIT_DIFF_FORMAT_PATCH;
}

static git_diff_options diff_opts_atom2type(ErlNifEnv *env, ERL_NIF_TERM keyword)
{
	ERL_NIF_TERM head, tail, key, val;
	unsigned int size;
    int arity;
	size_t i;
	const ERL_NIF_TERM *array;
	git_diff_options opts;

	git_diff_init_options(&opts, GIT_DIFF_OPTIONS_VERSION);

	if (!enif_get_list_length(env, keyword, &size))
		return opts;

	tail = keyword;
	for(i = 0; i < size; i++) {
		if (!enif_get_list_cell(env, tail, &head, &tail))
			return opts;

		if (!enif_get_tuple(env, head, &arity, &array))
			return opts;

		if (arity != 2 ) {
			return opts;
		}

		key = array[0];
		val = array[1];

		if (!enif_compare(key, atoms.diff_opts_context_lines))
			enif_get_uint(env, val, &opts.context_lines);
		else if (!enif_compare(key, atoms.diff_opts_interhunk_lines))
			enif_get_uint(env, val, &opts.interhunk_lines);
		else if (!enif_compare(key, atoms.diff_opts_pathspec)) {
			opts.pathspec = git_strarray_from_list(env, val);
		} else if (!enif_compare(key, atoms.diff_opts_exact_paths) && enif_is_identical(val, atoms.true)) {
			opts.flags |= GIT_DIFF_DISABLE_PATHSPEC_MATCH;
		}
	}

	return opts;
}

static ERL_NIF_TERM diff_file_to_term(ErlNifEnv *env, const git_diff_file *file)
{
	ErlNifBinary path, oid;

	if (git_engine_oid_bin(&oid, &file->id) < 0)
		return git_engine_oom(env);

	if (git_engine_string_to_bin(&path, file->path) < 0) {
		enif_release_binary(&path);
		return git_engine_oom(env);
	}

	return enif_make_tuple4(env,
		enif_make_binary(env, &oid),
		enif_make_binary(env, &path),
		enif_make_int64(env, file->size),
		enif_make_uint(env, file->mode)
	);
}

static ERL_NIF_TERM diff_line_to_term(ErlNifEnv *env, const git_diff_line *line)
{
	ErlNifBinary bin;

	if (enif_alloc_binary(line->content_len, &bin) < 0)
		return git_engine_oom(env);

	memcpy(bin.data, line->content, line->content_len);

	return enif_make_tuple6(env,
		enif_make_uint(env, line->origin),
		enif_make_int(env, line->old_lineno),
		enif_make_int(env, line->new_lineno),
		enif_make_int(env, line->num_lines),
		enif_make_int64(env, line->content_offset),
		enif_make_binary(env, &bin)
	);
}


static ERL_NIF_TERM diff_hunk_to_term(ErlNifEnv *env, const git_diff_hunk *hunk)
{
	ErlNifBinary header;

	if (git_engine_string_to_bin(&header, hunk->header) < 0) {
		enif_release_binary(&header);
		return git_engine_oom(env);
	}

	return enif_make_tuple5(env,
		enif_make_binary(env, &header),
		enif_make_int(env, hunk->old_start),
		enif_make_int(env, hunk->old_lines),
		enif_make_int(env, hunk->new_start),
		enif_make_int(env, hunk->new_lines)
	);
}

static ERL_NIF_TERM diff_delta_to_term(ErlNifEnv *env, const git_diff_delta *delta)
{
	return enif_make_tuple4(env,
		diff_file_to_term(env, &delta->old_file),
		diff_file_to_term(env, &delta->new_file),
		enif_make_uint(env, delta->nfiles),
		enif_make_uint(env, delta->similarity)
	);
}

static int diff_delta_file_cb(const git_diff_delta *delta, float progress, void *payload)
{
	diff_pack* pack = payload;
	diff_delta *delta_pack = malloc(sizeof(diff_delta));

	*delta_pack = (diff_delta){ diff_delta_to_term(pack->env, delta), NULL, 0 };
	pack->deltas[pack->size++] = delta_pack;
	return 0;
}

static int diff_delta_bin_cb(const git_diff_delta *delta, const git_diff_binary *binary, void *payload)
{
	return 0;
}

static int diff_delta_hunk_cb(const git_diff_delta *delta, const git_diff_hunk *hunk, void *payload)
{
	diff_pack* pack = payload;
	diff_delta *last_delta = pack->deltas[pack->size-1];
	if(last_delta->hunks == NULL) {
		last_delta->hunks = (diff_hunk **)malloc(sizeof(diff_hunk *));
		last_delta->size = 1;
	} else {
		last_delta->hunks = realloc(last_delta->hunks, sizeof(diff_hunk *) * ++last_delta->size);
	}

	diff_hunk *delta_hunk = malloc(sizeof(diff_hunk));

	*delta_hunk = (diff_hunk){ diff_hunk_to_term(pack->env, hunk), delta_hunk->lines = enif_make_list(pack->env, 0) };
	last_delta->hunks[last_delta->size-1] = delta_hunk;

	return 0;
}

static int diff_delta_line_cb(const git_diff_delta *delta, const git_diff_hunk *hunk, const git_diff_line *line, void *payload)
{
	diff_pack *pack = payload;
	diff_delta *last_delta = pack->deltas[pack->size-1];
	diff_hunk *last_hunk = last_delta->hunks[last_delta->size-1];
	last_hunk->lines = enif_make_list_cell(pack->env, diff_line_to_term(pack->env, line), last_hunk->lines);

	return 0;
}

void git_engine_diff_free(ErlNifEnv *env, void *cd)
{
	git_engine_diff *diff = (git_engine_diff *) cd;
	enif_release_resource(diff->repo);
	git_diff_free(diff->diff);
}

void git_engine_patch_free(ErlNifEnv *env, void *cd)
{
	git_engine_patch *patch = (git_engine_patch *) cd;
	git_patch_free(patch->patch);
	enif_release_resource(patch->diff);
}

ERL_NIF_TERM
git_engine_diff_tree(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int error;
	git_engine_repository *repo;
	git_engine_object *old_tree = NULL;
	git_engine_object *new_tree;
	git_engine_diff *diff;
	git_diff_options diff_opts;
	ERL_NIF_TERM diff_term;

	if (!enif_get_resource(env, argv[0], git_engine_repository_type, (void **) &repo))
		return enif_make_badarg(env);

	if (!enif_is_identical(argv[1], atoms.nil)) {
		if (!enif_get_resource(env, argv[1], git_engine_object_type, (void **) &old_tree))
			return enif_make_badarg(env);
	}

	if (!enif_get_resource(env, argv[2], git_engine_object_type, (void **) &new_tree))
		return enif_make_badarg(env);

	diff = enif_alloc_resource(git_engine_diff_type, sizeof(git_engine_diff));
	if (!diff)
		return git_engine_oom(env);

	diff_opts = diff_opts_atom2type(env, argv[3]);
	error = git_diff_tree_to_tree(&diff->diff, repo->repo, old_tree ? (git_tree *)old_tree->obj : NULL, (git_tree *)new_tree->obj, &diff_opts);
	if (error < 0) {
		enif_release_resource(diff);
		return git_engine_error_struct(env, error);
	}

	diff_term = enif_make_resource(env, diff);
	enif_release_resource(diff);
	diff->repo = repo;
	enif_keep_resource(repo);

	return enif_make_tuple2(env, atoms.ok, diff_term);
}

ERL_NIF_TERM
git_engine_diff_stats(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int error;
	git_engine_diff *diff;
	git_diff_stats *stats;
	int insertions, deletions, files_changed;

	if (!enif_get_resource(env, argv[0], git_engine_diff_type, (void **) &diff))
		return enif_make_badarg(env);

	error = git_diff_get_stats(&stats, diff->diff);
	if (error < 0)
		return git_engine_error_struct(env, error);

	insertions = git_diff_stats_insertions(stats);
	deletions = git_diff_stats_deletions(stats);
	files_changed = git_diff_stats_files_changed(stats);

	git_diff_stats_free(stats);

	return enif_make_tuple4(env, atoms.ok, enif_make_uint(env, files_changed), enif_make_uint(env, insertions), enif_make_uint(env, deletions));
}

ERL_NIF_TERM
git_engine_diff_delta_count(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	git_engine_diff *diff;

	if (!enif_get_resource(env, argv[0], git_engine_diff_type, (void **) &diff))
		return enif_make_badarg(env);

	return enif_make_tuple2(env, atoms.ok, enif_make_uint64(env, git_diff_num_deltas(diff->diff)));
}

ERL_NIF_TERM
git_engine_diff_deltas(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int error;
	diff_pack pack;
	git_engine_diff *diff;
	size_t i, j;

	if (!enif_get_resource(env, argv[0], git_engine_diff_type, (void **) &diff))
		return enif_make_badarg(env);

	pack = (diff_pack){ env, (diff_delta **)malloc(sizeof(git_diff_delta *) * git_diff_num_deltas(diff->diff)), 0};
	locale_t prev = uselocale(diff_c_locale());
	error = git_diff_foreach(diff->diff, diff_delta_file_cb, diff_delta_bin_cb, diff_delta_hunk_cb, diff_delta_line_cb, &pack);
	uselocale(prev);
	if (error < 0)
		return git_engine_error_struct(env, error);

	ERL_NIF_TERM deltas = enif_make_list(env, 0);
	for (i = 0; i < pack.size; i++) {
		diff_delta *delta = pack.deltas[i];
		ERL_NIF_TERM hunks = enif_make_list(env, 0);
		for (j = 0; j < delta->size; j++) {
			diff_hunk *hunk = delta->hunks[j];
			enif_make_reverse_list(env, hunk->lines, &hunk->lines);
			hunks = enif_make_list_cell(env, enif_make_tuple2(env, hunk->hunk, hunk->lines), hunks);
			free(hunk);
		}
		enif_make_reverse_list(env, hunks, &hunks);
		deltas = enif_make_list_cell(env, enif_make_tuple2(env, delta->delta, hunks), deltas);
		free(delta->hunks);
		free(delta);
	}

	enif_make_reverse_list(env, deltas, &deltas);
	free(pack.deltas);

	return enif_make_tuple2(env, atoms.ok, deltas);
}

static ERL_NIF_TERM diff_path_term(ErlNifEnv *env, const char *path)
{
	ErlNifBinary bin;

	if (git_engine_string_to_bin(&bin, path) < 0)
		return git_engine_oom(env);
	return enif_make_binary(env, &bin);
}

static ERL_NIF_TERM diff_outline_hunk(ErlNifEnv *env, git_patch *patch, size_t h)
{
	const git_diff_hunk *hunk;
	const git_diff_line *line;
	size_t nlines, l;
	ErlNifBinary origins;

	if (git_patch_get_hunk(&hunk, &nlines, patch, h) < 0 || !enif_alloc_binary(nlines, &origins))
		return git_engine_oom(env);

	for (l = 0; l < nlines; l++)
		origins.data[l] = git_patch_get_line_in_hunk(&line, patch, h, l) < 0 ? ' ' : line->origin;

	return enif_make_tuple5(env,
		enif_make_int(env, hunk->old_start),
		enif_make_int(env, hunk->old_lines),
		enif_make_int(env, hunk->new_start),
		enif_make_int(env, hunk->new_lines),
		enif_make_binary(env, &origins));
}

#define YIELD_EVERY 1000
#define YIELD_PERCENT 5

ERL_NIF_TERM
git_engine_diff_files(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	git_engine_diff *diff;
	ErlNifUInt64 offset, limit;
	size_t i, total, end;
	ERL_NIF_TERM files = enif_make_list(env, 0);

	if (!enif_get_resource(env, argv[0], git_engine_diff_type, (void **) &diff) ||
	    !enif_get_uint64(env, argv[1], &offset) || !enif_get_uint64(env, argv[2], &limit))
		return enif_make_badarg(env);

	total = git_diff_num_deltas(diff->diff);
	if (offset > total)
		offset = total;
	end = limit < total - offset ? offset + limit : total;

	for (i = end; i > offset;) {
		const git_diff_delta *delta = git_diff_get_delta(diff->diff, --i);
		files = enif_make_list_cell(env, enif_make_tuple4(env,
			enif_make_uint64(env, i),
			enif_make_uint(env, git_diff_status_char(delta->status)),
			diff_path_term(env, delta->old_file.path),
			diff_path_term(env, delta->new_file.path)), files);
	}

	return enif_make_tuple3(env, atoms.ok, enif_make_uint64(env, total), files);
}

static int diff_get_patch(git_patch **patch, ErlNifEnv *env, const ERL_NIF_TERM argv[], git_engine_diff **diff, size_t *index)
{
	ErlNifUInt64 i;
	int error;
	locale_t prev;

	if (!enif_get_resource(env, argv[0], git_engine_diff_type, (void **) diff) || !enif_get_uint64(env, argv[1], &i))
		return -2;
	if (i >= git_diff_num_deltas((*diff)->diff))
		return -3;

	*index = i;
	prev = uselocale(diff_c_locale());
	error = git_patch_from_diff(patch, (*diff)->diff, i);
	uselocale(prev);
	return error;
}

static ERL_NIF_TERM diff_patch_error(ErlNifEnv *env, int error)
{
	if (error == -2)
		return enif_make_badarg(env);
	if (error == -3)
		return enif_make_tuple2(env, atoms.error, atoms.nil);
	return git_engine_error_struct(env, error);
}

ERL_NIF_TERM
git_engine_diff_patch(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	git_engine_diff *diff;
	git_engine_patch *res;
	git_patch *patch = NULL;
	size_t index, h;
	ERL_NIF_TERM hunks = enif_make_list(env, 0), patch_term;
	int error = diff_get_patch(&patch, env, argv, &diff, &index);

	if (error < 0)
		return diff_patch_error(env, error);

	const git_diff_delta *delta = git_diff_get_delta(diff->diff, index);
	for (h = patch ? git_patch_num_hunks(patch) : 0; h-- > 0;)
		hunks = enif_make_list_cell(env, diff_outline_hunk(env, patch, h), hunks);

	ERL_NIF_TERM file = enif_make_tuple5(env,
		enif_make_uint(env, git_diff_status_char(delta->status)),
		diff_path_term(env, delta->old_file.path),
		diff_path_term(env, delta->new_file.path),
		(delta->flags & GIT_DIFF_FLAG_BINARY) ? atoms.true : atoms.false,
		hunks);

	res = enif_alloc_resource(git_engine_patch_type, sizeof(git_engine_patch));
	if (!res) {
		git_patch_free(patch);
		return git_engine_oom(env);
	}
	res->patch = patch;
	res->diff = diff;
	enif_keep_resource(diff);
	patch_term = enif_make_resource(env, res);
	enif_release_resource(res);

	return enif_make_tuple3(env, atoms.ok, patch_term, file);
}

typedef struct {
	ErlNifBinary bin;
	size_t size;
} diff_text;

static int diff_text_put(diff_text *text, const char *data, size_t len)
{
	if (text->size + len > text->bin.size &&
	    !enif_realloc_binary(&text->bin, (text->size + len) * 2))
		return -1;
	memcpy(text->bin.data + text->size, data, len);
	text->size += len;
	return 0;
}

static int diff_text_header_cb(const git_diff_delta *delta, const git_diff_hunk *hunk, const git_diff_line *line, void *payload)
{
	if (line->origin == GIT_DIFF_LINE_HUNK_HDR)
		return 1;
	return diff_text_put(payload, line->content, line->content_len);
}

static int diff_text_line(diff_text *text, const git_diff_line *line)
{
	if ((line->origin == GIT_DIFF_LINE_CONTEXT || line->origin == GIT_DIFF_LINE_ADDITION ||
	     line->origin == GIT_DIFF_LINE_DELETION) &&
	    diff_text_put(text, &line->origin, 1) < 0)
		return -1;
	return diff_text_put(text, line->content, line->content_len);
}

static int diff_text_take(ErlNifEnv *env, diff_text *text, ERL_NIF_TERM *chunks)
{
	if (!enif_realloc_binary(&text->bin, text->size)) {
		enif_release_binary(&text->bin);
		return -1;
	}
	*chunks = enif_make_list_cell(env, enif_make_binary(env, &text->bin), *chunks);
	return 0;
}

static ERL_NIF_TERM
patch_text_step(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	git_engine_patch *res;
	const git_diff_hunk *hunk;
	const git_diff_line *line;
	ErlNifUInt64 h, l, last;
	size_t nlines, done = 0;
	ERL_NIF_TERM chunks = argv[4];
	diff_text text = { .size = 0 };
	int error = 0;

	if (!enif_get_resource(env, argv[0], git_engine_patch_type, (void **) &res) ||
	    !enif_get_uint64(env, argv[1], &h) || !enif_get_uint64(env, argv[2], &l) ||
	    !enif_get_uint64(env, argv[3], &last))
		return enif_make_badarg(env);

	if (!enif_alloc_binary(4096, &text.bin))
		return git_engine_oom(env);

	for (; error >= 0 && h <= last; h++, l = 0) {
		error = git_patch_get_hunk(&hunk, &nlines, res->patch, h);
		if (error >= 0 && l == 0)
			error = diff_text_put(&text, hunk->header, hunk->header_len);

		for (; error >= 0 && l < nlines; l++) {
			error = git_patch_get_line_in_hunk(&line, res->patch, h, l);
			if (error >= 0)
				error = diff_text_line(&text, line);

			if (error >= 0 && ++done % YIELD_EVERY == 0 && enif_consume_timeslice(env, YIELD_PERCENT)) {
				if (diff_text_take(env, &text, &chunks) < 0)
					return git_engine_oom(env);
				ERL_NIF_TERM args[5] = { argv[0], enif_make_uint64(env, h), enif_make_uint64(env, l + 1), argv[3], chunks };
				return enif_schedule_nif(env, "patch_text", 0, patch_text_step, 5, args);
			}
		}
	}

	if (error < 0) {
		enif_release_binary(&text.bin);
		return git_engine_error_struct(env, error);
	}

	if (diff_text_take(env, &text, &chunks) < 0)
		return git_engine_oom(env);
	enif_make_reverse_list(env, chunks, &chunks);
	return enif_make_tuple2(env, atoms.ok, chunks);
}

ERL_NIF_TERM
git_engine_patch_text(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	git_engine_patch *res;
	long first, last;
	size_t count;
	int error;
	diff_text text = { .size = 0 };
	ERL_NIF_TERM chunks = enif_make_list(env, 0);

	if (!enif_get_resource(env, argv[0], git_engine_patch_type, (void **) &res) ||
	    !enif_get_long(env, argv[1], &first) || !enif_get_long(env, argv[2], &last) || first < 0)
		return enif_make_badarg(env);

	if (!res->patch)
		return enif_make_tuple2(env, atoms.ok, chunks);

	if (!enif_alloc_binary(4096, &text.bin))
		return git_engine_oom(env);

	error = git_patch_print(res->patch, diff_text_header_cb, &text);
	if (error < 0 && error != 1) {
		enif_release_binary(&text.bin);
		return git_engine_error_struct(env, error);
	}
	if (diff_text_take(env, &text, &chunks) < 0)
		return git_engine_oom(env);

	count = git_patch_num_hunks(res->patch);
	if (last < 0 || (size_t) last >= count)
		last = (long) count - 1;
	if (last < first) {
		enif_make_reverse_list(env, chunks, &chunks);
		return enif_make_tuple2(env, atoms.ok, chunks);
	}

	ERL_NIF_TERM args[5] = { argv[0], enif_make_uint64(env, first), enif_make_uint64(env, 0), enif_make_uint64(env, last), chunks };
	return patch_text_step(env, 5, args);
}

ERL_NIF_TERM
git_engine_diff_format(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int error;
	git_engine_diff *diff;
	git_buf buf = { NULL, 0, 0 };
	ErlNifBinary data;

	if (!enif_get_resource(env, argv[0], git_engine_diff_type, (void **) &diff))
		return enif_make_badarg(env);

	locale_t prev = uselocale(diff_c_locale());
	error = git_diff_to_buf(&buf, diff->diff, diff_format_atom2type(argv[1]));
	uselocale(prev);
	if (error < 0) {
		return git_engine_error_struct(env, error);
	}

	if (!enif_alloc_binary(buf.size, &data)) {
		git_buf_free(&buf);
		return git_engine_oom(env);
	}

	memcpy(data.data, buf.ptr, data.size);
	git_buf_free(&buf);

	return enif_make_tuple2(env, atoms.ok, enif_make_binary(env, &data));
}
