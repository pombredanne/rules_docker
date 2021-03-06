# Copyright 2017 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Rule for importing a container image."""

load(
    "//skylib:filetype.bzl",
    tar_filetype = "tar",
    tgz_filetype = "tgz",
)
load(
    "@bazel_tools//tools/build_defs/hash:hash.bzl",
    _hash_tools = "tools",
    _sha256 = "sha256",
)
load(
    "//skylib:zip.bzl",
    _gunzip = "gunzip",
    _gzip = "gzip",
)
load(
    "//container:layers.bzl",
    _assemble_image = "assemble",
    _incr_load = "incremental_load",
    _layer_tools = "tools",
)
load(
    "//skylib:path.bzl",
    "dirname",
    "strip_prefix",
    _canonicalize_path = "canonicalize",
    _join_path = "join",
)

def _is_filetype(filename, extensions):
  for filetype in extensions:
    if filename.endswith(filetype):
      return True

def _is_tgz(layer):
  return _is_filetype(layer.basename, tgz_filetype)

def _is_tar(layer):
  return _is_filetype(layer.basename, tar_filetype)

def _layer_pair(ctx, layer):
  zipped = _is_tgz(layer)
  unzipped = not zipped and _is_tar(layer)
  if not (zipped or unzipped):
    fail("Unknown filetype provided (need .tar or .tar.gz): %s" % layer)

  zipped_layer = layer if zipped else _gzip(ctx, layer)
  unzipped_layer = layer if unzipped else _gunzip(ctx, layer)
  return zipped_layer, unzipped_layer, _sha256(ctx, unzipped_layer)

def _repository_name(ctx):
  """Compute the repository name for the current rule."""
  return _join_path(ctx.attr.repository, ctx.label.package)

def _container_import_impl(ctx):
  """Implementation for the container_import rule."""

  blobsums = []
  zipped_layers = []
  unzipped_layers = []
  diff_ids = []
  for layer in ctx.files.layers:
    blobsums += [_sha256(ctx, layer)]
    zipped, unzipped, diff_id = _layer_pair(ctx, layer)
    zipped_layers += [zipped]
    unzipped_layers += [unzipped]
    diff_ids += [diff_id]

  # These are the constituent parts of the Container image, which each
  # rule in the chain must preserve.
  container_parts = {
      # The path to the v2.2 configuration file.
      "config": ctx.files.config[0],
      "config_digest": _sha256(ctx, ctx.files.config[0]),

      # A list of paths to the layer .tar.gz files
      "zipped_layer": zipped_layers,
      # A list of paths to the layer digests.
      "blobsum": blobsums,

      # A list of paths to the layer .tar files
      "unzipped_layer": unzipped_layers,
      # A list of paths to the layer diff_ids.
      "diff_id": diff_ids,

      # We do not have a "legacy" field, because we are importing a
      # more efficient form.
  }

  # We support incrementally loading or assembling this single image
  # with a temporary name given by its build rule.
  images = {
      _repository_name(ctx) + ":" + ctx.label.name: container_parts
  }

  _incr_load(ctx, images, ctx.outputs.executable)
  _assemble_image(ctx, images, ctx.outputs.out)

  runfiles = ctx.runfiles(
      files = (container_parts["unzipped_layer"] +
               container_parts["diff_id"] +
               [container_parts["config"],
                container_parts["config_digest"]]))
  return struct(runfiles = runfiles,
                files = depset([ctx.outputs.out]),
                container_parts = container_parts)

container_import = rule(
    attrs = {
        "config": attr.label(allow_files = [".json"]),
        "layers": attr.label_list(allow_files = tar_filetype + tgz_filetype),
        "repository": attr.string(default = "bazel"),
    } + _hash_tools + _layer_tools,
    executable = True,
    outputs = {
        "out": "%{name}.tar",
    },
    implementation = _container_import_impl,
)
