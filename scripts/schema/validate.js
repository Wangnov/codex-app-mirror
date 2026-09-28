#!/usr/bin/env node
// Validates one or more release-manifest.json files against
// schemas/release-manifest.schema.json using ajv (JSON Schema 2020-12).
//
// Usage:
//   node validate.js <schema.json> <file1.json> [file2.json ...]
//   node validate.js <schema.json> --expect-invalid <file1.json> [...]
//
// Exit code is 0 when every file matches the expected outcome (valid by
// default, or invalid when --expect-invalid is given), non-zero otherwise.
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const Ajv2020 = require("ajv/dist/2020").default;
const addFormats = require("ajv-formats");

function readJson(filePath) {
  const raw = fs.readFileSync(filePath, "utf8");
  try {
    return JSON.parse(raw);
  } catch (err) {
    throw new Error(`${filePath}: invalid JSON (${err.message})`);
  }
}

function main(argv) {
  const args = argv.slice(2);
  if (args.length < 2) {
    console.error(
      "usage: validate.js <schema.json> [--expect-invalid] <file...>"
    );
    return 2;
  }

  const schemaPath = args.shift();
  let expectInvalid = false;
  if (args[0] === "--expect-invalid") {
    expectInvalid = true;
    args.shift();
  }
  if (args.length === 0) {
    console.error("no manifest files given");
    return 2;
  }

  const schema = readJson(schemaPath);
  const ajv = new Ajv2020({
    allErrors: true,
    strict: false,
  });
  addFormats(ajv);
  const validate = ajv.compile(schema);

  let failures = 0;
  for (const file of args) {
    const rel = path.relative(process.cwd(), file);
    let data;
    try {
      data = readJson(file);
    } catch (err) {
      console.error(`FAIL ${rel}: ${err.message}`);
      failures += 1;
      continue;
    }

    const valid = validate(data);
    if (expectInvalid) {
      if (valid) {
        console.error(
          `FAIL ${rel}: expected schema validation to reject this fixture, but it passed`
        );
        failures += 1;
      } else {
        console.log(`ok   ${rel} (correctly rejected)`);
      }
      continue;
    }

    if (valid) {
      console.log(`ok   ${rel}`);
    } else {
      console.error(`FAIL ${rel}:`);
      for (const err of validate.errors) {
        const instancePath = err.instancePath || "(root)";
        console.error(`       ${instancePath} ${err.message}`);
      }
      failures += 1;
    }
  }

  if (failures > 0) {
    console.error(`\n${failures} of ${args.length} file(s) failed.`);
    return 1;
  }
  console.log(`\nAll ${args.length} file(s) passed.`);
  return 0;
}

process.exit(main(process.argv));
