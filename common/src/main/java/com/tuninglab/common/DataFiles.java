package com.tuninglab.common;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.List;
import java.util.regex.Pattern;
import java.util.stream.Stream;

/**
 * 공식 생성기가 병렬 모드로 만든 분할 파일까지 찾아준다.
 *
 *   dsdgen -parallel 4 -child 1  →  store_sales_1_4.dat
 *   dbgen  -C 4 -S 1             →  lineitem.tbl.1
 *
 * 단일 파일(store_sales.dat / lineitem.tbl)도 당연히 매칭된다.
 * "customer" 로 조회할 때 customer_address.dat 가 섞이지 않도록 정규식으로 정확히 구분한다.
 */
public final class DataFiles {

    private DataFiles() {}

    /** TPC-DS: {table}.dat 또는 {table}_{child}_{parallel}.dat */
    public static List<Path> findDat(Path dir, String table) {
        return find(dir, Pattern.compile(Pattern.quote(table) + "(_\\d+_\\d+)?\\.dat"));
    }

    /** TPC-H: {table}.tbl 또는 {table}.tbl.{child} */
    public static List<Path> findTbl(Path dir, String table) {
        return find(dir, Pattern.compile(Pattern.quote(table) + "\\.tbl(\\.\\d+)?"));
    }

    private static List<Path> find(Path dir, Pattern pattern) {
        if (!Files.isDirectory(dir)) {
            return List.of();
        }
        try (Stream<Path> files = Files.list(dir)) {
            return files.filter(Files::isRegularFile)
                    .filter(p -> pattern.matcher(p.getFileName().toString()).matches())
                    .sorted(Comparator.comparing(p -> p.getFileName().toString()))
                    .toList();
        } catch (IOException e) {
            throw new UncheckedIOException("Cannot list " + dir, e);
        }
    }
}
