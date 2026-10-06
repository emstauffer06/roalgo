// Independent reference values for lab/src/Model/Ridge.luau (plan Section 5, Task 4).
//
// This script deliberately shares no code or algorithm with the Luau module under test:
//   * two-pass column means and population standard deviations (Ridge.luau uses a Welford co-moment stream),
//   * an explicitly standardised design matrix Z (Ridge.luau never materialises Z),
//   * Gauss-Jordan elimination with partial pivoting on [A | B] (Ridge.luau uses Cholesky).
// Run from the project root:  node lab/fixtures/dev/ridge-reference.mjs
// Writes lab/fixtures/ridge-reference.json and its Luau mirror lab/fixtures/ridge_reference.luau.
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { toLuau } from "../../../tools/luau-literal.mjs";

const STD_THRESHOLD = 1e-12; // plan Section 5: drop columns with training std < 1e-12

function fitReference(X, Y, lambda) {
  const n = X.length;
  const p = X[0].length;
  const heads = Y[0].length;
  const colMean = [];
  const colStd = [];
  for (let j = 0; j < p; j++) {
    let s = 0;
    for (let i = 0; i < n; i++) s += X[i][j];
    const m = s / n;
    let ss = 0;
    for (let i = 0; i < n; i++) ss += (X[i][j] - m) ** 2;
    colMean.push(m);
    colStd.push(Math.sqrt(ss / n));
  }
  const retained = [];
  for (let j = 0; j < p; j++) if (colStd[j] >= STD_THRESHOLD) retained.push(j);
  const targetMeans = [];
  for (let h = 0; h < heads; h++) {
    let s = 0;
    for (let i = 0; i < n; i++) s += Y[i][h];
    targetMeans.push(s / n);
  }
  const r = retained.length;
  const Z = X.map((row) => retained.map((j) => (row[j] - colMean[j]) / colStd[j]));
  const A = [];
  const B = [];
  for (let a = 0; a < r; a++) {
    A.push([]);
    for (let b = 0; b < r; b++) {
      let s = 0;
      for (let i = 0; i < n; i++) s += Z[i][a] * Z[i][b];
      A[a].push(s / n + (a === b ? lambda : 0));
    }
    B.push([]);
    for (let h = 0; h < heads; h++) {
      let s = 0;
      for (let i = 0; i < n; i++) s += Z[i][a] * (Y[i][h] - targetMeans[h]);
      B[a].push(s / n);
    }
  }
  const beta = gaussJordan(A, B);
  return {
    retained: retained.map((j) => j + 1), // 1-based, like the Luau model
    means: retained.map((j) => colMean[j]),
    scales: retained.map((j) => colStd[j]),
    targetMeans,
    beta,
  };
}

function gaussJordan(A, B) {
  const r = A.length;
  const heads = B.length > 0 ? B[0].length : 0;
  const M = A.map((row, i) => [...row, ...B[i]]);
  for (let c = 0; c < r; c++) {
    let piv = c;
    for (let i = c + 1; i < r; i++) if (Math.abs(M[i][c]) > Math.abs(M[piv][c])) piv = i;
    if (Math.abs(M[piv][c]) < 1e-14) throw new Error(`reference: singular system at column ${c}`);
    [M[c], M[piv]] = [M[piv], M[c]];
    const d = M[c][c];
    for (let k = c; k < r + heads; k++) M[c][k] /= d;
    for (let i = 0; i < r; i++) {
      if (i === c) continue;
      const f = M[i][c];
      if (f === 0) continue;
      for (let k = c; k < r + heads; k++) M[i][k] -= f * M[c][k];
    }
  }
  return M.map((row) => row.slice(r));
}

function predictReference(model, row) {
  return model.targetMeans.map((ym, h) => {
    let s = ym;
    model.retained.forEach((j1, a) => {
      s += ((row[j1 - 1] - model.means[a]) / model.scales[a]) * model.beta[a][h];
    });
    return s;
  });
}

const cases = [
  {
    name: "mixed",
    note: "9 rows, 4 columns: column 2 is constant (dropped), columns 1 and 3 correlated, column 4 a 0/1 mask; two heads",
    X: [
      [-1.5, 2.5, -0.7, 1],
      [-0.8, 2.5, -1.1, 0],
      [-0.2, 2.5, 0.3, 1],
      [0.1, 2.5, -0.2, 1],
      [0.4, 2.5, 0.9, 0],
      [0.9, 2.5, 0.4, 1],
      [1.3, 2.5, 1.6, 0],
      [2.0, 2.5, 1.2, 1],
      [2.6, 2.5, 2.9, 1],
    ],
    Y: [
      [0.3, -1.2],
      [-0.1, 0.4],
      [0.8, -0.3],
      [0.5, 0.1],
      [1.4, -0.9],
      [1.1, 0.7],
      [2.3, -1.6],
      [2.1, 0.2],
      [3.7, -0.5],
    ],
    lambdas: [0, 0.1, 10],
    queries: [
      [0, 2.5, 0, 0],
      [1.7, 99, -0.4, 1],
      [-3, -1, 4, 0.5],
    ],
  },
  {
    name: "duplicate",
    note: "two identical columns: singular for lambda=0, solvable for lambda>0",
    X: [
      [1, 1],
      [2, 2],
      [4, 4],
      [7, 7],
      [11, 11],
      [16, 16],
    ],
    Y: [
      [1, 5],
      [3, 4],
      [2, 6],
      [6, 2],
      [5, 3],
      [9, 1],
    ],
    lambdas: [0.5, 3],
    queries: [
      [0, 0],
      [5, 5],
      [20, 20],
    ],
  },
];

const out = {
  schema: "mrl-ridge-reference-1",
  generator: "lab/fixtures/dev/ridge-reference.mjs",
  method: "two-pass mean/population std, explicit standardised Z, Gauss-Jordan with partial pivoting",
  cases: cases.map((c) => ({
    name: c.name,
    note: c.note,
    X: c.X,
    Y: c.Y,
    queries: c.queries,
    fits: c.lambdas.map((lambda) => {
      const model = fitReference(c.X, c.Y, lambda);
      return { lambda, ...model, predictions: c.queries.map((q) => predictReference(model, q)) };
    }),
  })),
};

const here = dirname(fileURLToPath(import.meta.url));
const fixtures = join(here, "..");
writeFileSync(join(fixtures, "ridge-reference.json"), JSON.stringify(out, null, 2) + "\n", { encoding: "utf8" });
const luau =
  "-- GENERATED by lab/fixtures/dev/ridge-reference.mjs (independent two-pass + Gauss-Jordan reference).\n" +
  "-- Mirrors lab/fixtures/ridge-reference.json. Do not edit by hand; rerun the generator.\n" +
  "return " +
  toLuau(out) +
  "\n";
writeFileSync(join(fixtures, "ridge_reference.luau"), luau, { encoding: "utf8" });
console.log(`wrote ${out.cases.length} cases, ${out.cases.reduce((s, c) => s + c.fits.length, 0)} fits`);
