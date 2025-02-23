/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */
/*                                                                       */
/*    This file is part of the HiGHS linear optimization suite           */
/*                                                                       */
/*    Written and engineered 2008-2021 at the University of Edinburgh    */
/*                                                                       */
/*    Available as open-source under the MIT License                     */
/*                                                                       */
/*    Authors: Julian Hall, Ivet Galabova, Qi Huangfu, Leona Gottwald    */
/*    and Michael Feldmeier                                              */
/*                                                                       */
/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */
/**@file mip/HighsModKSeparator.cpp
 */

#include "mip/HighsModkSeparator.h"

#include <unordered_set>

#include "mip/HighsCutGeneration.h"
#include "mip/HighsGFkSolve.h"
#include "mip/HighsLpAggregator.h"
#include "mip/HighsLpRelaxation.h"
#include "mip/HighsMipSolverData.h"
#include "mip/HighsTransformedLp.h"
#include "pdqsort/pdqsort.h"
#include "util/HighsHash.h"
#include "util/HighsIntegers.h"

template <HighsInt k, typename FoundModKCut>
static void separateModKCuts(const std::vector<int64_t>& intSystemValue,
                             const std::vector<HighsInt>& intSystemIndex,
                             const std::vector<HighsInt>& intSystemStart,
                             HighsInt numCol, FoundModKCut&& foundModKCut) {
  HighsGFkSolve GFkSolve;

  GFkSolve.fromCSC<k>(intSystemValue, intSystemIndex, intSystemStart,
                      numCol + 1);
  GFkSolve.setRhs<k>(numCol, k - 1);
  GFkSolve.solve<k>(foundModKCut);
}

void HighsModkSeparator::separateLpSolution(HighsLpRelaxation& lpRelaxation,
                                            HighsLpAggregator& lpAggregator,
                                            HighsTransformedLp& transLp,
                                            HighsCutPool& cutpool) {
  const HighsMipSolver& mipsolver = lpRelaxation.getMipSolver();
  const HighsLp& lp = lpRelaxation.getLp();

  std::vector<uint8_t> skipRow(lp.num_row_);

  // mark all rows that have continuous variables with a nonzero solution value
  // in the transformed LP to be skipped
  for (HighsInt col : mipsolver.mipdata_->continuous_cols) {
    if (transLp.boundDistance(col) == 0) continue;

    const HighsInt start = lp.a_matrix_.start_[col];
    const HighsInt end = lp.a_matrix_.start_[col + 1];

    for (HighsInt i = start; i != end; ++i)
      skipRow[lp.a_matrix_.index_[i]] = true;
  }

  HighsCutGeneration cutGen(lpRelaxation, cutpool);

  std::vector<std::pair<HighsInt, double>> integralScales;
  std::vector<int64_t> intSystemValue;
  std::vector<HighsInt> intSystemIndex;
  std::vector<HighsInt> intSystemStart;

  intSystemValue.reserve(lp.a_matrix_.value_.size() + lp.num_row_);
  intSystemIndex.reserve(intSystemValue.size());
  intSystemStart.reserve(lp.num_row_ + 1);
  intSystemStart.push_back(0);
  std::vector<HighsInt> inds;
  std::vector<double> vals;
  std::vector<double> scaleVals;

  std::vector<double> upper;
  std::vector<double> solval;
  double rhs;

  const HighsSolution& lpSolution = lpRelaxation.getSolution();
  HighsInt numNonzeroRhs = 0;
  HighsInt maxIntRowLen = 1000 + 0.1 * lp.num_col_;

  for (HighsInt row = 0; row != lp.num_row_; ++row) {
    if (skipRow[row]) continue;

    bool leqRow;
    if (lp.row_upper_[row] - lpSolution.row_value[row] <=
        mipsolver.mipdata_->feastol)
      leqRow = true;
    else if (lpSolution.row_value[row] - lp.row_lower_[row] <=
             mipsolver.mipdata_->feastol)
      leqRow = false;
    else
      continue;

    HighsInt rowlen;
    const HighsInt* rowinds;
    const double* rowvals;

    lpRelaxation.getRow(row, rowlen, rowinds, rowvals);

    if (leqRow) {
      rhs = lp.row_upper_[row];
      inds.assign(rowinds, rowinds + rowlen);
      vals.assign(rowvals, rowvals + rowlen);
    } else {
      assert(lpSolution.row_value[row] - lp.row_lower_[row] <=
             mipsolver.mipdata_->feastol);

      rhs = -lp.row_lower_[row];
      inds.assign(rowinds, rowinds + rowlen);
      vals.resize(rowlen);
      std::transform(rowvals, rowvals + rowlen, vals.begin(),
                     [](double x) { return -x; });
    }

    bool integralPositive = false;
    if (!transLp.transform(vals, upper, solval, inds, rhs, integralPositive,
                           true))
      continue;

    rowlen = inds.size();

    double intscale;
    int64_t intrhs;

    if (!lpRelaxation.isRowIntegral(row)) {
      for (HighsInt i = 0; i != rowlen; ++i) {
        if (mipsolver.variableType(inds[i]) == HighsVarType::kContinuous)
          continue;
        if (transLp.boundDistance(inds[i]) > 0) scaleVals.push_back(vals[i]);
      }
      scaleVals.push_back(-rhs);

      intscale = HighsIntegers::integralScale(vals, mipsolver.mipdata_->feastol,
                                              mipsolver.mipdata_->epsilon);
      if (intscale == 0.0 || intscale > 1e6) continue;

      intrhs = std::round(intscale * rhs);

      for (HighsInt i = 0; i != rowlen; ++i) {
        if (mipsolver.variableType(inds[i]) == HighsVarType::kContinuous)
          continue;
        if (solval[i] > mipsolver.mipdata_->feastol) {
          intSystemIndex.push_back(inds[i]);
          intSystemValue.push_back((int64_t)std::round(intscale * vals[i]));
        }
      }
    } else {
      intscale = 1.0;
      intrhs = (int64_t)std::round(rhs);

      for (HighsInt i = 0; i != rowlen; ++i) {
        if (solval[i] > mipsolver.mipdata_->feastol) {
          intSystemIndex.push_back(inds[i]);
          intSystemValue.push_back((int64_t)std::round(vals[i]));
        }
      }
    }

    HighsInt intRowLen = intSystemValue.size() - intSystemStart.back();
    if (intRowLen <= maxIntRowLen) {
      numNonzeroRhs += (intrhs != 0);

      intSystemIndex.push_back(lp.num_col_);
      intSystemValue.push_back(intrhs);
      intSystemStart.push_back(intSystemValue.size());
      if (leqRow)
        integralScales.emplace_back(row, intscale);
      else
        integralScales.emplace_back(row, -intscale);
    } else {
      intSystemIndex.resize(intSystemStart.back());
      intSystemValue.resize(intSystemStart.back());
    }
  }

  if (integralScales.empty() || numNonzeroRhs == 0) return;

  std::vector<HighsInt> tmpinds;
  std::vector<double> tmpvals;

  HighsHashTable<std::vector<HighsGFkSolve::SolutionEntry>> usedWeights;
  // std::unordered_set<std::vector<HighsGFkSolve::SolutionEntry>,
  //                   HighsVectorHasher, HighsVectorEqual>
  //    usedWeights;
  HighsInt k;
  auto foundCut = [&](std::vector<HighsGFkSolve::SolutionEntry>& weights) {
    // cuts which come from a single row can already be found with the
    // aggregation heuristic
    if (weights.size() <= 1) return;

    pdqsort(weights.begin(), weights.end());
    if (!usedWeights.insert(weights)) return;

    for (const auto& w : weights) {
      HighsInt row = integralScales[w.index].first;
      double weight = (integralScales[w.index].second * w.weight) / k;
      lpAggregator.addRow(row, weight);
    }

    lpAggregator.getCurrentAggregation(inds, vals, false);

    rhs = 0.0;
    cutGen.generateCut(transLp, inds, vals, rhs, true);

    lpAggregator.getCurrentAggregation(inds, vals, true);

    rhs = 0.0;
    cutGen.generateCut(transLp, inds, vals, rhs, true);
  };

  k = 2;
  HighsInt numCuts = -cutpool.getNumCuts();
  separateModKCuts<2>(intSystemValue, intSystemIndex, intSystemStart,
                      lp.num_col_, foundCut);
  numCuts += cutpool.getNumCuts();
  if (numCuts > 0) return;

  k = 3;
  numCuts = -cutpool.getNumCuts();
  separateModKCuts<3>(intSystemValue, intSystemIndex, intSystemStart,
                      lp.num_col_, foundCut);
  numCuts += cutpool.getNumCuts();
  if (numCuts > 0) return;

  k = 5;
  numCuts = -cutpool.getNumCuts();
  separateModKCuts<5>(intSystemValue, intSystemIndex, intSystemStart,
                      lp.num_col_, foundCut);
  numCuts += cutpool.getNumCuts();
  if (numCuts > 0) return;

  k = 7;
  numCuts = -cutpool.getNumCuts();
  separateModKCuts<7>(intSystemValue, intSystemIndex, intSystemStart,
                      lp.num_col_, foundCut);
  numCuts += cutpool.getNumCuts();
}
