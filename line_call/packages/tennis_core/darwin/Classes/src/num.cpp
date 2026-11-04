#include "tennis/num.hpp"

#include <algorithm>
#include <cmath>

namespace tennis {
namespace num {
namespace {

// Solve a 1x1..3x3 symmetric positive-definite system (normal equations)
// via Cholesky-free Gaussian elimination with partial pivoting.
bool Solve(double* a, double* b, int n, std::vector<double>& x) {
  double m[3][4];
  for (int i = 0; i < n; ++i) {
    for (int j = 0; j < n; ++j) m[i][j] = a[i * n + j];
    m[i][n] = b[i];
  }
  for (int c = 0; c < n; ++c) {
    int p = c;
    for (int r = c + 1; r < n; ++r)
      if (std::fabs(m[r][c]) > std::fabs(m[p][c])) p = r;
    if (m[p][c] == 0.0) return false;
    if (p != c)
      for (int k = c; k <= n; ++k) std::swap(m[c][k], m[p][k]);
    for (int r = c + 1; r < n; ++r) {
      double f = m[r][c] / m[c][c];
      for (int k = c; k <= n; ++k) m[r][k] -= f * m[c][k];
    }
  }
  x.assign(n, 0.0);
  for (int r = n - 1; r >= 0; --r) {
    double s = m[r][n];
    for (int k = r + 1; k < n; ++k) s -= m[r][k] * x[k];
    x[r] = s / m[r][r];
  }
  return true;
}

}  // namespace

bool PolyFit(const std::vector<double>& t, const std::vector<double>& y,
             int deg, std::vector<double>& coef) {
  const int n = static_cast<int>(t.size());
  const int p = deg + 1;
  if (n < p || deg < 0 || deg > 2) return false;
  // Shift t for conditioning (exact same fit, better numerics).
  double t0 = t[n / 2];
  double ata[9] = {0};
  double atb[3] = {0};
  for (int i = 0; i < n; ++i) {
    double u = t[i] - t0;
    double pw[3] = {1.0, u, u * u};
    for (int a = 0; a < p; ++a) {
      atb[a] += pw[a] * y[i];
      for (int b = 0; b < p; ++b) ata[a * p + b] += pw[a] * pw[b];
    }
  }
  std::vector<double> asc;
  if (!Solve(ata, atb, p, asc)) return false;
  // Convert ascending-in-u back to descending-in-t coefficients.
  if (deg == 0) {
    coef = {asc[0]};
  } else if (deg == 1) {
    coef = {asc[1], asc[0] - asc[1] * t0};
  } else {
    double a = asc[2], b = asc[1], c = asc[0];
    coef = {a, b - 2 * a * t0, c - b * t0 + a * t0 * t0};
  }
  return true;
}

double PolyVal(const std::vector<double>& coef, double t) {
  double v = 0.0;
  for (double c : coef) v = v * t + c;
  return v;
}

std::vector<double> Gradient(const std::vector<double>& y,
                             const std::vector<double>& x) {
  const int n = static_cast<int>(y.size());
  std::vector<double> g(n, 0.0);
  if (n == 0) return g;
  if (n == 1) return g;
  g[0] = (y[1] - y[0]) / (x[1] - x[0]);
  for (int i = 1; i < n - 1; ++i) {
    double h0 = x[i] - x[i - 1], h1 = x[i + 1] - x[i];
    // Second-order central difference on a non-uniform grid.
    g[i] = (h0 * h0 * y[i + 1] + (h1 * h1 - h0 * h0) * y[i] -
            h1 * h1 * y[i - 1]) /
           (h0 * h1 * (h0 + h1));
  }
  g[n - 1] = (y[n - 1] - y[n - 2]) / (x[n - 1] - x[n - 2]);
  return g;
}

double Median(std::vector<double> v) {
  const size_t n = v.size();
  if (n == 0) return 0.0;
  std::nth_element(v.begin(), v.begin() + n / 2, v.end());
  double hi = v[n / 2];
  if (n % 2 == 1) return hi;
  std::nth_element(v.begin(), v.begin() + n / 2 - 1, v.end());
  return 0.5 * (v[n / 2 - 1] + hi);
}

bool SolveN(const std::vector<double>& a, const std::vector<double>& b, int n,
            std::vector<double>& x) {
  if (n < 1 || n > 8 || (int)a.size() != n * n || (int)b.size() != n)
    return false;
  double m[8][9];
  for (int i = 0; i < n; ++i) {
    for (int j = 0; j < n; ++j) m[i][j] = a[i * n + j];
    m[i][n] = b[i];
  }
  for (int c = 0; c < n; ++c) {
    int p = c;
    for (int r = c + 1; r < n; ++r)
      if (std::fabs(m[r][c]) > std::fabs(m[p][c])) p = r;
    if (m[p][c] == 0.0) return false;
    if (p != c)
      for (int k = c; k <= n; ++k) std::swap(m[c][k], m[p][k]);
    for (int r = c + 1; r < n; ++r) {
      double f = m[r][c] / m[c][c];
      for (int k = c; k <= n; ++k) m[r][k] -= f * m[c][k];
    }
  }
  x.assign(n, 0.0);
  for (int r = n - 1; r >= 0; --r) {
    double s = m[r][n];
    for (int k = r + 1; k < n; ++k) s -= m[r][k] * x[k];
    x[r] = s / m[r][r];
  }
  return true;
}

void Eigh2Top(double e00, double e01, double e11, double& val, double& vx,
              double& vy) {
  double tr = e00 + e11, det = e00 * e11 - e01 * e01;
  double disc = std::sqrt(std::max(0.0, tr * tr / 4 - det));
  val = tr / 2 + disc;
  // Eigenvector for the larger eigenvalue: (e01, val - e00).
  vx = e01;
  vy = val - e00;
  double n = std::hypot(vx, vy);
  if (n < 1e-12) {
    vx = 1;
    vy = 0;
  } else {
    vx /= n;
    vy /= n;
  }
}

bool Invert3(const double m[9], double inv[9]) {
  double det = m[0] * (m[4] * m[8] - m[5] * m[7]) -
               m[1] * (m[3] * m[8] - m[5] * m[6]) +
               m[2] * (m[3] * m[7] - m[4] * m[6]);
  if (det == 0.0) return false;
  double s = 1.0 / det;
  inv[0] = (m[4] * m[8] - m[5] * m[7]) * s;
  inv[1] = (m[2] * m[7] - m[1] * m[8]) * s;
  inv[2] = (m[1] * m[5] - m[2] * m[4]) * s;
  inv[3] = (m[5] * m[6] - m[3] * m[8]) * s;
  inv[4] = (m[0] * m[8] - m[2] * m[6]) * s;
  inv[5] = (m[2] * m[3] - m[0] * m[5]) * s;
  inv[6] = (m[3] * m[7] - m[4] * m[6]) * s;
  inv[7] = (m[1] * m[6] - m[0] * m[7]) * s;
  inv[8] = (m[0] * m[4] - m[1] * m[3]) * s;
  return true;
}

std::vector<double> SavGol2(const std::vector<double>& y, int w) {
  const int n = static_cast<int>(y.size());
  std::vector<double> out = y;
  if (w < 3 || n < w) return out;
  const int h = w / 2;
  // Convolution weights for the center: least-squares fit over
  // offsets -h..h evaluated at 0 (poly 2).
  std::vector<double> t(w);
  for (int i = 0; i < w; ++i) t[i] = i - h;
  // Build the pseudo-inverse row for offset 0 via normal equations.
  double ata[9] = {0};
  for (int i = 0; i < w; ++i) {
    double pw[3] = {1.0, t[i], t[i] * t[i]};
    for (int a = 0; a < 3; ++a)
      for (int b = 0; b < 3; ++b) ata[a * 3 + b] += pw[a] * pw[b];
  }
  // Weight of sample j = e0' (A'A)^-1 a_j; solve (A'A) z = e0 once.
  double e0[3] = {1.0, 0.0, 0.0};
  std::vector<double> z;
  if (!Solve(ata, e0, 3, z)) return out;
  std::vector<double> cw(w);
  for (int j = 0; j < w; ++j)
    cw[j] = z[0] + z[1] * t[j] + z[2] * t[j] * t[j];
  for (int i = h; i < n - h; ++i) {
    double s = 0.0;
    for (int j = 0; j < w; ++j) s += cw[j] * y[i - h + j];
    out[i] = s;
  }
  // mode="interp" edges: fit the first/last full window, evaluate at
  // the edge positions.
  for (int e = 0; e < h; ++e) {
    std::vector<double> te(w), ye(w);
    for (int j = 0; j < w; ++j) {
      te[j] = j;
      ye[j] = y[j];
    }
    std::vector<double> c;
    if (PolyFit(te, ye, 2, c)) out[e] = PolyVal(c, e);
    for (int j = 0; j < w; ++j) {
      te[j] = n - w + j;
      ye[j] = y[n - w + j];
    }
    if (PolyFit(te, ye, 2, c)) out[n - 1 - e] = PolyVal(c, n - 1 - e);
  }
  return out;
}

}  // namespace num
}  // namespace tennis
