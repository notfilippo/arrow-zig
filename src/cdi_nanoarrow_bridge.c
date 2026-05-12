// Copyright 2026 Filippo Rossi
// SPDX-License-Identifier: Apache-2.0

#include "nanoarrow/nanoarrow.h"

#define TRY(EXPR)                       \
  do {                                  \
    int code_ = (EXPR);                 \
    if (code_ != NANOARROW_OK) {        \
      return code_;                     \
    }                                   \
  } while (0)

typedef int (*ArrowZigFixtureBuilder)(
    struct ArrowSchema* schema,
    struct ArrowArray* array);

static int arrow_zig_start_array(
    struct ArrowSchema* schema,
    struct ArrowArray* array) {
  TRY(ArrowArrayInitFromSchema(array, schema, NULL));
  return ArrowArrayStartAppending(array);
}

static int arrow_zig_finish_array(struct ArrowArray* array) {
  return ArrowArrayFinishBuildingDefault(array, NULL);
}

static int arrow_zig_build_fixture(
    struct ArrowSchema* schema,
    struct ArrowArray* array,
    ArrowZigFixtureBuilder build) {
  schema->release = NULL;
  array->release = NULL;

  int code = build(schema, array);
  if (code != NANOARROW_OK) {
    if (array->release != NULL) {
      ArrowArrayRelease(array);
    }
    if (schema->release != NULL) {
      ArrowSchemaRelease(schema);
    }
  }
  return code;
}

static int arrow_zig_build_null(
    struct ArrowSchema* schema,
    struct ArrowArray* array) {
  TRY(ArrowSchemaInitFromType(schema, NANOARROW_TYPE_NA));
  TRY(arrow_zig_start_array(schema, array));
  TRY(ArrowArrayAppendNull(array, 3));
  return arrow_zig_finish_array(array);
}

static int arrow_zig_build_bool(
    struct ArrowSchema* schema,
    struct ArrowArray* array) {
  TRY(ArrowSchemaInitFromType(schema, NANOARROW_TYPE_BOOL));
  TRY(arrow_zig_start_array(schema, array));
  TRY(ArrowArrayAppendInt(array, 1));
  TRY(ArrowArrayAppendNull(array, 1));
  TRY(ArrowArrayAppendInt(array, 0));
  return arrow_zig_finish_array(array);
}

static int arrow_zig_build_int32(
    struct ArrowSchema* schema,
    struct ArrowArray* array) {
  TRY(ArrowSchemaInitFromType(schema, NANOARROW_TYPE_INT32));
  TRY(arrow_zig_start_array(schema, array));
  TRY(ArrowArrayAppendInt(array, 11));
  TRY(ArrowArrayAppendNull(array, 1));
  TRY(ArrowArrayAppendInt(array, 33));
  return arrow_zig_finish_array(array);
}

static int arrow_zig_build_string(
    struct ArrowSchema* schema,
    struct ArrowArray* array) {
  TRY(ArrowSchemaInitFromType(schema, NANOARROW_TYPE_STRING));
  TRY(arrow_zig_start_array(schema, array));
  TRY(ArrowArrayAppendString(array, ArrowCharView("aa")));
  TRY(ArrowArrayAppendNull(array, 1));
  TRY(ArrowArrayAppendString(array, ArrowCharView("bbb")));
  return arrow_zig_finish_array(array);
}

static int arrow_zig_build_list_int32(
    struct ArrowSchema* schema,
    struct ArrowArray* array) {
  ArrowSchemaInit(schema);
  TRY(ArrowSchemaSetType(schema, NANOARROW_TYPE_LIST));
  TRY(ArrowSchemaSetType(schema->children[0], NANOARROW_TYPE_INT32));

  TRY(arrow_zig_start_array(schema, array));
  TRY(ArrowArrayAppendInt(array->children[0], 1));
  TRY(ArrowArrayAppendInt(array->children[0], 2));
  TRY(ArrowArrayFinishElement(array));
  TRY(ArrowArrayFinishElement(array));
  TRY(ArrowArrayAppendNull(array, 1));
  TRY(ArrowArrayAppendInt(array->children[0], 3));
  TRY(ArrowArrayFinishElement(array));
  return arrow_zig_finish_array(array);
}

static int arrow_zig_build_struct(
    struct ArrowSchema* schema,
    struct ArrowArray* array) {
  ArrowSchemaInit(schema);
  TRY(ArrowSchemaSetTypeStruct(schema, 2));
  TRY(ArrowSchemaSetType(schema->children[0], NANOARROW_TYPE_INT32));
  TRY(ArrowSchemaSetName(schema->children[0], "number"));
  TRY(ArrowSchemaSetType(schema->children[1], NANOARROW_TYPE_STRING));
  TRY(ArrowSchemaSetName(schema->children[1], "word"));

  TRY(arrow_zig_start_array(schema, array));
  TRY(ArrowArrayAppendInt(array->children[0], 4));
  TRY(ArrowArrayAppendString(array->children[1], ArrowCharView("four")));
  TRY(ArrowArrayFinishElement(array));
  TRY(ArrowArrayAppendInt(array->children[0], 5));
  TRY(ArrowArrayAppendString(array->children[1], ArrowCharView("five")));
  TRY(ArrowArrayFinishElement(array));
  return arrow_zig_finish_array(array);
}

static int arrow_zig_build_dictionary(
    struct ArrowSchema* schema,
    struct ArrowArray* array) {
  TRY(ArrowSchemaInitFromType(schema, NANOARROW_TYPE_INT16));
  TRY(ArrowSchemaAllocateDictionary(schema));
  TRY(ArrowSchemaInitFromType(schema->dictionary, NANOARROW_TYPE_STRING));

  TRY(arrow_zig_start_array(schema, array));
  TRY(ArrowArrayAppendString(array->dictionary, ArrowCharView("alpha")));
  TRY(ArrowArrayAppendString(array->dictionary, ArrowCharView("beta")));
  TRY(ArrowArrayAppendInt(array, 0));
  TRY(ArrowArrayAppendInt(array, 1));
  TRY(ArrowArrayAppendNull(array, 1));
  TRY(ArrowArrayAppendInt(array, 0));
  return arrow_zig_finish_array(array);
}

int arrow_zig_nanoarrow_make_null(
    struct ArrowSchema* schema,
    struct ArrowArray* array) {
  return arrow_zig_build_fixture(schema, array, arrow_zig_build_null);
}

int arrow_zig_nanoarrow_make_bool(
    struct ArrowSchema* schema,
    struct ArrowArray* array) {
  return arrow_zig_build_fixture(schema, array, arrow_zig_build_bool);
}

int arrow_zig_nanoarrow_make_int32(
    struct ArrowSchema* schema,
    struct ArrowArray* array) {
  return arrow_zig_build_fixture(schema, array, arrow_zig_build_int32);
}

int arrow_zig_nanoarrow_make_string(
    struct ArrowSchema* schema,
    struct ArrowArray* array) {
  return arrow_zig_build_fixture(schema, array, arrow_zig_build_string);
}

int arrow_zig_nanoarrow_make_list_int32(
    struct ArrowSchema* schema,
    struct ArrowArray* array) {
  return arrow_zig_build_fixture(schema, array, arrow_zig_build_list_int32);
}

int arrow_zig_nanoarrow_make_struct(
    struct ArrowSchema* schema,
    struct ArrowArray* array) {
  return arrow_zig_build_fixture(schema, array, arrow_zig_build_struct);
}

int arrow_zig_nanoarrow_make_dictionary(
    struct ArrowSchema* schema,
    struct ArrowArray* array) {
  return arrow_zig_build_fixture(schema, array, arrow_zig_build_dictionary);
}
