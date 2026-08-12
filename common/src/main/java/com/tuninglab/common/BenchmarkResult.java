package com.tuninglab.common;

import java.util.List;

/** 단일 쿼리 벤치마크 결과 (밀리초 단위). */
public record BenchmarkResult(
        String name,
        int iterations,
        long rowCount,
        List<Double> timesMs) {

    public double min() { return timesMs.stream().mapToDouble(Double::doubleValue).min().orElse(0); }
    public double max() { return timesMs.stream().mapToDouble(Double::doubleValue).max().orElse(0); }
    public double avg() { return timesMs.stream().mapToDouble(Double::doubleValue).average().orElse(0); }

    public double percentile(double p) {
        List<Double> sorted = timesMs.stream().sorted().toList();
        if (sorted.isEmpty()) return 0;
        int idx = (int) Math.ceil(p / 100.0 * sorted.size()) - 1;
        return sorted.get(Math.max(0, Math.min(idx, sorted.size() - 1)));
    }

    public String summaryLine() {
        return String.format("%-8s rows=%-10d runs=%-3d min=%9.1fms avg=%9.1fms p95=%9.1fms max=%9.1fms",
                name, rowCount, iterations, min(), avg(), percentile(95), max());
    }
}
