// Tiny numeric helpers mirroring the numpy/scipy calls the engine uses:
// least-squares polyfit (deg 1-2), polyval, non-uniform gradient,
// median, Savitzky-Golay (poly 2, interp edges, like scipy).
#pragma once

#include <cstddef>
#include <vector>

namespace tennis {
namespace num {

// Fit y ~ c0 + c1*t (+ c2*t^2). Returns false when underdetermined.
bool PolyFit(const std::vector<double>& t, const std::vector<double>& y,
             int deg, std::vector<double>& coef);
// Highest-power-first coefficients, like np.polyval/polyfit.
double PolyVal(const std::vector<double>& coef, double t);

// np.gradient(y, x) with edge_order=1: second-order central interior,
// first-order one-sided edges. x must be strictly increasing.
std::vector<double> Gradient(const std::vector<double>& y,
                             const std::vector<double>& x);

double Median(std::vector<double> v);

// Savitzky-Golay, poly 2, scipy mode="interp" semantics: center points
// from the windowed least-squares fit; edge points from a fit over the
// first/last full window evaluated at the edge positions. w must be odd.
std::vector<double> SavGol2(const std::vector<double>& y, int w);

// Solve the n x n system A x = b (row-major A, n <= 8). False if singular.
bool SolveN(const std::vector<double>& a, const std::vector<double>& b, int n,
            std::vector<double>& x);

// Top eigenpair of symmetric [[e00,e01],[e01,e11]]: eigenvalue + unit vector.
void Eigh2Top(double e00, double e01, double e11, double& val, double& vx,
              double& vy);

// Invert a row-major 3x3. False if singular.
bool Invert3(const double m[9], double inv[9]);

}  // namespace num
}  // namespace tennis
