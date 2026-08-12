package com.tuninglab.tpch;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.BufferedWriter;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDate;
import java.util.Random;

/**
 * TPC-H 스타일 데이터 생성기 (Java 구현).
 *
 * 공식 dbgen과 동일한 테이블 구조/행수 비율('|' 구분 .tbl)을 만들지만,
 * 값의 분포는 단순화된 근사치다. 실행계획/인덱스/조인 튜닝 실습에는 충분하며,
 * 공식 감사 수준의 데이터가 필요하면 scripts/tpch/gen-official-dbgen.sh 를 사용한다.
 *
 * 행수 공식 (SF = scale factor):
 *   region 5, nation 25, supplier 10K*SF, customer 150K*SF,
 *   part 200K*SF, partsupp 800K*SF, orders 1.5M*SF, lineitem ≈ 6M*SF
 *
 * SF=1   → lineitem 약 600만 건 (~1GB)
 * SF=17  → lineitem 약 1억 건
 * SF=100 → lineitem 약 6억 건 (~100GB, 공식 dbgen 권장)
 */
public class TpchDataGenerator {

    private static final Logger log = LoggerFactory.getLogger(TpchDataGenerator.class);

    private static final String[] REGIONS = {"AFRICA", "AMERICA", "ASIA", "EUROPE", "MIDDLE EAST"};
    private static final String[][] NATIONS = {
            {"ALGERIA", "0"}, {"ARGENTINA", "1"}, {"BRAZIL", "1"}, {"CANADA", "1"},
            {"EGYPT", "4"}, {"ETHIOPIA", "0"}, {"FRANCE", "3"}, {"GERMANY", "3"},
            {"INDIA", "2"}, {"INDONESIA", "2"}, {"IRAN", "4"}, {"IRAQ", "4"},
            {"JAPAN", "2"}, {"JORDAN", "4"}, {"KENYA", "0"}, {"MOROCCO", "0"},
            {"MOZAMBIQUE", "0"}, {"PERU", "1"}, {"CHINA", "2"}, {"ROMANIA", "3"},
            {"SAUDI ARABIA", "4"}, {"VIETNAM", "2"}, {"RUSSIA", "3"},
            {"UNITED KINGDOM", "3"}, {"UNITED STATES", "1"}};
    private static final String[] SEGMENTS =
            {"AUTOMOBILE", "BUILDING", "FURNITURE", "MACHINERY", "HOUSEHOLD"};
    private static final String[] PRIORITIES =
            {"1-URGENT", "2-HIGH", "3-MEDIUM", "4-NOT SPECIFIED", "5-LOW"};
    private static final String[] SHIP_MODES =
            {"REG AIR", "AIR", "RAIL", "SHIP", "TRUCK", "MAIL", "FOB"};
    private static final String[] SHIP_INSTRUCT =
            {"DELIVER IN PERSON", "COLLECT COD", "NONE", "TAKE BACK RETURN"};
    private static final String[] CONTAINERS = {
            "SM CASE", "SM BOX", "SM PACK", "SM PKG", "MED BAG", "MED BOX", "MED PKG",
            "LG CASE", "LG BOX", "LG PACK", "LG PKG", "JUMBO BAG", "JUMBO BOX",
            "WRAP CASE", "WRAP BOX"};
    private static final String[] COLORS = {
            "almond", "antique", "aquamarine", "azure", "beige", "bisque", "black",
            "blanched", "blue", "blush", "brown", "burlywood", "burnished", "chartreuse",
            "chiffon", "chocolate", "coral", "cornflower", "cream", "cyan", "dark",
            "deep", "dim", "dodger", "drab", "firebrick", "floral", "forest", "frosted",
            "gainsboro", "ghost", "goldenrod", "green", "grey", "honeydew", "hot",
            "indian", "ivory", "khaki", "lace", "lavender", "lawn", "lemon", "light",
            "lime", "linen", "magenta", "maroon", "medium", "metallic", "midnight",
            "mint", "misty", "moccasin", "navajo", "navy", "olive", "orange", "orchid",
            "pale", "papaya", "peach", "peru", "pink", "plum", "powder", "puff",
            "purple", "red", "rose", "rosy", "royal", "saddle", "salmon", "sandy",
            "seashell", "sienna", "sky", "slate", "smoke", "snow", "spring", "steel",
            "tan", "thistle", "tomato", "turquoise", "violet", "wheat", "white", "yellow"};
    private static final String[] TYPE_SYLLABLE1 =
            {"STANDARD", "SMALL", "MEDIUM", "LARGE", "ECONOMY", "PROMO"};
    private static final String[] TYPE_SYLLABLE2 =
            {"ANODIZED", "BURNISHED", "PLATED", "POLISHED", "BRUSHED"};
    private static final String[] TYPE_SYLLABLE3 =
            {"TIN", "NICKEL", "BRASS", "STEEL", "COPPER"};
    private static final String[] WORDS = {
            "furiously", "quickly", "carefully", "slyly", "blithely", "final",
            "special", "pending", "regular", "express", "ironic", "even", "bold",
            "silent", "daring", "requests", "deposits", "instructions", "accounts",
            "packages", "foxes", "ideas", "theodolites", "pinto", "beans", "asymptotes",
            "dependencies", "excuses", "platelets", "sleep", "haggle", "nag", "wake",
            "cajole", "detect", "integrate", "boost", "engage", "along", "among"};

    private static final LocalDate START_DATE = LocalDate.of(1992, 1, 1);
    private static final LocalDate END_ORDER_DATE = LocalDate.of(1998, 8, 2);

    private final double sf;
    private final Path dir;

    public TpchDataGenerator(double sf, Path dir) {
        this.sf = sf;
        this.dir = dir;
    }

    public void generateAll() throws IOException {
        Files.createDirectories(dir);
        long suppliers = Math.round(10_000 * sf);
        long customers = Math.round(150_000 * sf);
        long parts = Math.round(200_000 * sf);
        long orders = Math.round(1_500_000 * sf);

        log.info("Generating TPC-H data: SF={} → suppliers={}, customers={}, parts={}, orders={} (dir={})",
                sf, suppliers, customers, parts, orders, dir.toAbsolutePath());

        generateRegion();
        generateNation();
        generateSupplier(suppliers);
        generateCustomer(customers);
        generatePart(parts);
        generatePartsupp(parts, suppliers);
        generateOrdersAndLineitem(orders, customers, parts, suppliers);

        log.info("Done. Files written to {}", dir.toAbsolutePath());
    }

    private void generateRegion() throws IOException {
        try (BufferedWriter w = open("region.tbl")) {
            Random rnd = new Random(11);
            for (int i = 0; i < REGIONS.length; i++) {
                row(w, i, REGIONS[i], comment(rnd, 60));
            }
        }
    }

    private void generateNation() throws IOException {
        try (BufferedWriter w = open("nation.tbl")) {
            Random rnd = new Random(22);
            for (int i = 0; i < NATIONS.length; i++) {
                row(w, i, NATIONS[i][0], NATIONS[i][1], comment(rnd, 70));
            }
        }
    }

    private void generateSupplier(long count) throws IOException {
        try (BufferedWriter w = open("supplier.tbl")) {
            Random rnd = new Random(33);
            for (long k = 1; k <= count; k++) {
                int nation = rnd.nextInt(25);
                row(w, k,
                        String.format("Supplier#%09d", k),
                        address(rnd),
                        nation,
                        phone(rnd, nation),
                        money(rnd, -999_99, 9999_99),
                        comment(rnd, 60));
            }
        }
        log.info("supplier.tbl: {} rows", count);
    }

    private void generateCustomer(long count) throws IOException {
        try (BufferedWriter w = open("customer.tbl")) {
            Random rnd = new Random(44);
            for (long k = 1; k <= count; k++) {
                int nation = rnd.nextInt(25);
                row(w, k,
                        String.format("Customer#%09d", k),
                        address(rnd),
                        nation,
                        phone(rnd, nation),
                        money(rnd, -999_99, 9999_99),
                        SEGMENTS[rnd.nextInt(SEGMENTS.length)],
                        comment(rnd, 70));
            }
        }
        log.info("customer.tbl: {} rows", count);
    }

    private void generatePart(long count) throws IOException {
        try (BufferedWriter w = open("part.tbl")) {
            Random rnd = new Random(55);
            for (long k = 1; k <= count; k++) {
                String name = COLORS[rnd.nextInt(COLORS.length)] + " "
                        + COLORS[rnd.nextInt(COLORS.length)] + " "
                        + COLORS[rnd.nextInt(COLORS.length)] + " "
                        + COLORS[rnd.nextInt(COLORS.length)] + " "
                        + COLORS[rnd.nextInt(COLORS.length)];
                int mfgr = 1 + rnd.nextInt(5);
                int brand = mfgr * 10 + 1 + rnd.nextInt(5);
                String type = TYPE_SYLLABLE1[rnd.nextInt(TYPE_SYLLABLE1.length)] + " "
                        + TYPE_SYLLABLE2[rnd.nextInt(TYPE_SYLLABLE2.length)] + " "
                        + TYPE_SYLLABLE3[rnd.nextInt(TYPE_SYLLABLE3.length)];
                // 공식 retail price 공식
                long price = (90_000 + (k % 20_001) + 100 * (k % 1_000));
                row(w, k, name,
                        String.format("Manufacturer#%d", mfgr),
                        String.format("Brand#%d", brand),
                        type,
                        1 + rnd.nextInt(50),
                        CONTAINERS[rnd.nextInt(CONTAINERS.length)],
                        cents(price),
                        comment(rnd, 15));
            }
        }
        log.info("part.tbl: {} rows", count);
    }

    private void generatePartsupp(long parts, long suppliers) throws IOException {
        try (BufferedWriter w = open("partsupp.tbl")) {
            Random rnd = new Random(66);
            for (long p = 1; p <= parts; p++) {
                for (int i = 0; i < 4; i++) {
                    // 공식 dbgen의 supplier 분산 공식
                    long s = (p + i * (suppliers / 4 + (p - 1) / suppliers)) % suppliers + 1;
                    row(w, p, s,
                            1 + rnd.nextInt(9999),
                            money(rnd, 1_00, 1000_00),
                            comment(rnd, 120));
                }
            }
        }
        log.info("partsupp.tbl: {} rows", parts * 4);
    }

    private void generateOrdersAndLineitem(long orders, long customers, long parts, long suppliers)
            throws IOException {
        long lineCount = 0;
        try (BufferedWriter ow = open("orders.tbl");
             BufferedWriter lw = open("lineitem.tbl")) {
            Random rnd = new Random(77);
            int orderDateRange = (int) (END_ORDER_DATE.toEpochDay() - START_DATE.toEpochDay());

            for (long o = 1; o <= orders; o++) {
                long custkey = 1 + (long) (rnd.nextDouble() * customers);
                LocalDate orderDate = START_DATE.plusDays(rnd.nextInt(orderDateRange));
                int lines = 1 + rnd.nextInt(7);
                long totalCents = 0;
                boolean allShipped = true;

                for (int ln = 1; ln <= lines; ln++) {
                    long partkey = 1 + (long) (rnd.nextDouble() * parts);
                    long suppkey = 1 + (long) (rnd.nextDouble() * suppliers);
                    int qty = 1 + rnd.nextInt(50);
                    long unitPriceCents = 90_000 + (partkey % 20_001) + 100 * (partkey % 1_000);
                    long extendedCents = unitPriceCents * qty;
                    int discount = rnd.nextInt(11);          // 0.00 ~ 0.10
                    int tax = rnd.nextInt(9);                // 0.00 ~ 0.08
                    LocalDate shipDate = orderDate.plusDays(1 + rnd.nextInt(121));
                    LocalDate commitDate = orderDate.plusDays(30 + rnd.nextInt(61));
                    LocalDate receiptDate = shipDate.plusDays(1 + rnd.nextInt(30));

                    boolean shipped = shipDate.isBefore(LocalDate.of(1995, 6, 17));
                    allShipped &= shipped;
                    String returnFlag = shipped ? (rnd.nextInt(2) == 0 ? "R" : "A") : "N";
                    String lineStatus = shipped ? "F" : "O";

                    totalCents += extendedCents * (100 - discount) / 100 * (100 + tax) / 100;

                    row(lw, o, partkey, suppkey, ln,
                            qty + ".00",
                            cents(extendedCents),
                            cents(discount),
                            cents(tax),
                            returnFlag, lineStatus,
                            shipDate, commitDate, receiptDate,
                            SHIP_INSTRUCT[rnd.nextInt(SHIP_INSTRUCT.length)],
                            SHIP_MODES[rnd.nextInt(SHIP_MODES.length)],
                            comment(rnd, 30));
                    lineCount++;
                }

                String status = allShipped ? "F" : (rnd.nextInt(2) == 0 ? "O" : "P");
                row(ow, o, custkey, status,
                        cents(totalCents),
                        orderDate,
                        PRIORITIES[rnd.nextInt(PRIORITIES.length)],
                        String.format("Clerk#%09d", 1 + rnd.nextInt((int) Math.max(1, orders / 1000))),
                        0,
                        comment(rnd, 50));

                if (o % 500_000 == 0) {
                    log.info("orders: {}/{} (lineitem {} rows)", o, orders, lineCount);
                }
            }
        }
        log.info("orders.tbl: {} rows, lineitem.tbl: {} rows", orders, lineCount);
    }

    // ---------- helpers ----------

    private BufferedWriter open(String file) throws IOException {
        return Files.newBufferedWriter(dir.resolve(file), StandardCharsets.UTF_8);
    }

    private void row(BufferedWriter w, Object... cols) {
        try {
            StringBuilder sb = new StringBuilder(160);
            for (Object c : cols) {
                sb.append(c).append('|');
            }
            sb.append('\n');
            w.write(sb.toString());
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    private String comment(Random rnd, int approxLen) {
        StringBuilder sb = new StringBuilder(approxLen + 12);
        while (sb.length() < approxLen) {
            if (sb.length() > 0) sb.append(' ');
            sb.append(WORDS[rnd.nextInt(WORDS.length)]);
        }
        return sb.substring(0, Math.min(sb.length(), approxLen));
    }

    private String address(Random rnd) {
        int len = 10 + rnd.nextInt(30);
        StringBuilder sb = new StringBuilder(len);
        String alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ,";
        for (int i = 0; i < len; i++) {
            sb.append(alphabet.charAt(rnd.nextInt(alphabet.length())));
        }
        return sb.toString().trim();
    }

    private String phone(Random rnd, int nation) {
        return String.format("%d-%03d-%03d-%04d", 10 + nation,
                100 + rnd.nextInt(900), 100 + rnd.nextInt(900), 1000 + rnd.nextInt(9000));
    }

    private String money(Random rnd, long minCents, long maxCents) {
        long v = minCents + (long) (rnd.nextDouble() * (maxCents - minCents));
        return cents(v);
    }

    private String cents(long totalCents) {
        boolean neg = totalCents < 0;
        long abs = Math.abs(totalCents);
        return (neg ? "-" : "") + (abs / 100) + "." + String.format("%02d", abs % 100);
    }
}
