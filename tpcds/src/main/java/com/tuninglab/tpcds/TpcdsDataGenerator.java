package com.tuninglab.tpcds;

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
 * TPC-DS 스타일 샘플 데이터 생성기 (store_sales 채널 9개 테이블).
 *
 * 공식 dsdgen 과 동일한 컬럼 배치의 '|' 구분 .dat 파일을 만들지만 분포는 근사치다.
 * 실행계획/Star Join/윈도우 함수 튜닝 실습용이며, 공식 데이터가 필요하면
 * scripts/tpcds/gen-official-dsdgen.sh 를 사용한다.
 *
 * --sales 파라미터가 store_sales 행수를 결정한다.
 *   sales=1_000_000    : 빠른 실습용 (~200MB)
 *   sales=100_000_000  : 1억 건 (RAW 약 40GB, 공식 dsdgen -scale 100 권장)
 */
public class TpcdsDataGenerator {

    private static final Logger log = LoggerFactory.getLogger(TpcdsDataGenerator.class);

    private static final LocalDate CAL_START = LocalDate.of(1998, 1, 1);
    private static final LocalDate CAL_END = LocalDate.of(2002, 12, 31);
    private static final String[] DAY_NAMES =
            {"Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"};
    private static final String[] CATEGORIES =
            {"Books", "Children", "Electronics", "Home", "Jewelry",
             "Men", "Music", "Shoes", "Sports", "Women"};
    private static final String[] EDUCATION = {"Primary", "Secondary", "College",
            "2 yr Degree", "4 yr Degree", "Advanced Degree", "Unknown"};
    private static final String[] MARITAL = {"M", "S", "D", "W", "U"};
    private static final String[] CREDIT = {"Low Risk", "Good", "High Risk", "Unknown"};
    private static final String[] BUY_POTENTIAL =
            {"0-500", "501-1000", "1001-5000", "5001-10000", ">10000", "Unknown"};
    private static final String[] STATES =
            {"CA", "TX", "NY", "FL", "IL", "PA", "OH", "GA", "NC", "MI", "WA", "TN"};
    private static final String[] FIRST_NAMES = {"James", "Mary", "John", "Patricia",
            "Robert", "Jennifer", "Michael", "Linda", "David", "Elizabeth"};
    private static final String[] LAST_NAMES = {"Smith", "Johnson", "Williams", "Brown",
            "Jones", "Garcia", "Miller", "Davis", "Rodriguez", "Martinez"};

    private final long sales;
    private final Path dir;

    private final int days;
    private final long items;
    private final long customers;
    private final long addresses;
    private final long cdemos;
    private final long hdemos = 7200;
    private final int stores = 12;
    private final int promotions = 300;

    public TpcdsDataGenerator(long sales, Path dir) {
        this.sales = sales;
        this.dir = dir;
        this.days = (int) (CAL_END.toEpochDay() - CAL_START.toEpochDay()) + 1;
        this.items = Math.max(2_000, sales / 100);
        this.customers = Math.max(10_000, sales / 30);
        this.addresses = Math.max(5_000, customers / 2);
        this.cdemos = Math.min(1_920_800, Math.max(50_000, sales / 20));
    }

    public void generateAll() throws IOException {
        Files.createDirectories(dir);
        log.info("Generating TPC-DS sample: sales={}, items={}, customers={}, cdemos={} (dir={})",
                sales, items, customers, cdemos, dir.toAbsolutePath());
        generateDateDim();
        generateItem();
        generateStore();
        generateCustomerAddress();
        generateCustomerDemographics();
        generateHouseholdDemographics();
        generateCustomer();
        generatePromotion();
        generateStoreSales();
        log.info("Done. Files written to {}", dir.toAbsolutePath());
    }

    private void generateDateDim() throws IOException {
        try (BufferedWriter w = open("date_dim.dat")) {
            for (int i = 0; i < days; i++) {
                LocalDate d = CAL_START.plusDays(i);
                int sk = 2450815 + i;   // 공식 dsdgen과 유사한 sk 대역
                int qoy = (d.getMonthValue() - 1) / 3 + 1;
                boolean weekend = d.getDayOfWeek().getValue() >= 6;
                row(w, sk,
                        String.format("AAAAAAAA%08d", i),
                        d,
                        (d.getYear() - 1900) * 12 + d.getMonthValue() - 1,
                        i / 7,
                        (d.getYear() - 1900) * 4 + qoy - 1,
                        d.getYear(),
                        d.getDayOfWeek().getValue() % 7,
                        d.getMonthValue(),
                        d.getDayOfMonth(),
                        qoy,
                        d.getYear(),
                        (d.getYear() - 1900) * 4 + qoy - 1,
                        i / 7,
                        DAY_NAMES[d.getDayOfWeek().getValue() - 1],
                        d.getYear() + "Q" + qoy,
                        "N",
                        weekend ? "Y" : "N",
                        "N",
                        sk - d.getDayOfMonth() + 1,
                        sk - d.getDayOfMonth() + d.lengthOfMonth(),
                        sk - 365, sk - 90,
                        "N", "N", "N", "N", "N");
            }
        }
        log.info("date_dim.dat: {} rows", days);
    }

    private void generateItem() throws IOException {
        try (BufferedWriter w = open("item.dat")) {
            Random rnd = new Random(101);
            for (long k = 1; k <= items; k++) {
                int categoryId = rnd.nextInt(CATEGORIES.length);
                int classId = 1 + rnd.nextInt(16);
                int brandId = (categoryId + 1) * 1_000_000 + classId * 1000 + rnd.nextInt(100);
                int manufactId = 1 + rnd.nextInt(1000);
                row(w, k,
                        String.format("AAAAAAAA%08d", k),
                        CAL_START, "",
                        "item description " + k,
                        cents(100 + rnd.nextInt(9900)),
                        cents(50 + rnd.nextInt(5000)),
                        brandId,
                        "Brand#" + (categoryId + 1) + classId,
                        classId,
                        "class" + classId,
                        categoryId + 1,
                        CATEGORIES[categoryId],
                        manufactId,
                        "manufact#" + manufactId,
                        "medium", "formulation", "steel", "Each", "Unknown",
                        1 + rnd.nextInt(100),
                        "product " + k);
            }
        }
        log.info("item.dat: {} rows", items);
    }

    private void generateStore() throws IOException {
        try (BufferedWriter w = open("store.dat")) {
            Random rnd = new Random(102);
            for (int k = 1; k <= stores; k++) {
                row(w, k,
                        String.format("AAAAAAAA%08d", k),
                        CAL_START, "", "",
                        "Store " + k,
                        50 + rnd.nextInt(250),
                        5_000_000 + rnd.nextInt(5_000_000),
                        "8AM-10PM",
                        FIRST_NAMES[rnd.nextInt(FIRST_NAMES.length)] + " "
                                + LAST_NAMES[rnd.nextInt(LAST_NAMES.length)],
                        1 + rnd.nextInt(10),
                        "Unknown", "market description", "Manager " + k,
                        1, "Unknown", 1, "Unknown",
                        String.valueOf(100 + k), "Main", "Street", "Suite " + k,
                        "Midway", "Williamson County",
                        STATES[rnd.nextInt(STATES.length)],
                        String.format("%05d", 10000 + rnd.nextInt(89999)),
                        "United States", "-5.00", "0.0" + rnd.nextInt(9));
            }
        }
        log.info("store.dat: {} rows", stores);
    }

    private void generateCustomerAddress() throws IOException {
        try (BufferedWriter w = open("customer_address.dat")) {
            Random rnd = new Random(103);
            for (long k = 1; k <= addresses; k++) {
                row(w, k,
                        String.format("AAAAAAAA%08d", k),
                        String.valueOf(1 + rnd.nextInt(999)),
                        "Oak", "Street", "Suite " + rnd.nextInt(400),
                        "Pleasant Hill", "Williamson County",
                        STATES[rnd.nextInt(STATES.length)],
                        String.format("%05d", 10000 + rnd.nextInt(89999)),
                        "United States", "-5.00",
                        rnd.nextInt(2) == 0 ? "apartment" : "single family");
            }
        }
        log.info("customer_address.dat: {} rows", addresses);
    }

    private void generateCustomerDemographics() throws IOException {
        try (BufferedWriter w = open("customer_demographics.dat")) {
            for (long k = 1; k <= cdemos; k++) {
                long v = k - 1;
                String gender = (v % 2 == 0) ? "M" : "F";
                String marital = MARITAL[(int) ((v / 2) % MARITAL.length)];
                String edu = EDUCATION[(int) ((v / 10) % EDUCATION.length)];
                int purchase = 500 + (int) ((v / 70) % 20) * 500;
                String credit = CREDIT[(int) ((v / 1400) % CREDIT.length)];
                row(w, k, gender, marital, edu, purchase, credit,
                        v % 7, (v / 7) % 7, (v / 49) % 7);
            }
        }
        log.info("customer_demographics.dat: {} rows", cdemos);
    }

    private void generateHouseholdDemographics() throws IOException {
        try (BufferedWriter w = open("household_demographics.dat")) {
            for (long k = 1; k <= hdemos; k++) {
                long v = k - 1;
                row(w, k,
                        1 + v % 20,
                        BUY_POTENTIAL[(int) (v % BUY_POTENTIAL.length)],
                        v % 10, v % 5);
            }
        }
        log.info("household_demographics.dat: {} rows", hdemos);
    }

    private void generateCustomer() throws IOException {
        try (BufferedWriter w = open("customer.dat")) {
            Random rnd = new Random(104);
            for (long k = 1; k <= customers; k++) {
                String first = FIRST_NAMES[rnd.nextInt(FIRST_NAMES.length)];
                String last = LAST_NAMES[rnd.nextInt(LAST_NAMES.length)];
                row(w, k,
                        String.format("AAAAAAAA%08d", k),
                        1 + rnd.nextLong(cdemos),
                        1 + rnd.nextLong(hdemos),
                        1 + rnd.nextLong(addresses),
                        2450815 + rnd.nextInt(days),
                        2450815 + rnd.nextInt(days),
                        rnd.nextInt(2) == 0 ? "Mr." : "Ms.",
                        first, last,
                        rnd.nextInt(2) == 0 ? "Y" : "N",
                        1 + rnd.nextInt(28),
                        1 + rnd.nextInt(12),
                        1930 + rnd.nextInt(65),
                        "United States", "",
                        (first + "." + last + k + "@example.com").toLowerCase(),
                        2450815 + rnd.nextInt(days));
            }
        }
        log.info("customer.dat: {} rows", customers);
    }

    private void generatePromotion() throws IOException {
        try (BufferedWriter w = open("promotion.dat")) {
            Random rnd = new Random(105);
            for (int k = 1; k <= promotions; k++) {
                int start = 2450815 + rnd.nextInt(days - 60);
                row(w, k,
                        String.format("AAAAAAAA%08d", k),
                        start, start + 30 + rnd.nextInt(30),
                        1 + rnd.nextLong(items),
                        "1000.00", 1,
                        "promo#" + k,
                        yn(rnd), yn(rnd), yn(rnd), yn(rnd),
                        yn(rnd), yn(rnd), yn(rnd), yn(rnd),
                        "promotion details " + k, "Unknown", yn(rnd));
            }
        }
        log.info("promotion.dat: {} rows", promotions);
    }

    private void generateStoreSales() throws IOException {
        try (BufferedWriter w = open("store_sales.dat")) {
            Random rnd = new Random(106);
            long ticket = 0;
            long written = 0;
            while (written < sales) {
                ticket++;
                int itemsInTicket = 1 + rnd.nextInt(8);
                int dateSk = 2450815 + rnd.nextInt(days);
                long custSk = 1 + rnd.nextLong(customers);
                long cdemoSk = 1 + rnd.nextLong(cdemos);
                long hdemoSk = 1 + rnd.nextLong(hdemos);
                long addrSk = 1 + rnd.nextLong(addresses);
                int storeSk = 1 + rnd.nextInt(stores);

                // store_sales PK = (ss_item_sk, ss_ticket_number) 이므로
                // 한 영수증 안에서 같은 상품이 두 번 나오면 안 된다 (공식 dsdgen과 동일한 제약).
                // 충돌 시 선형 탐사로 다음 item_sk를 잡는다 (itemsInTicket <= 8 << items 이므로 항상 종료).
                java.util.Set<Long> itemsInThisTicket = new java.util.HashSet<>();

                for (int i = 0; i < itemsInTicket && written < sales; i++) {
                    long itemSk = 1 + rnd.nextLong(items);
                    while (!itemsInThisTicket.add(itemSk)) {
                        itemSk = itemSk % items + 1;
                    }
                    long promoSk = 1 + rnd.nextInt(promotions);
                    int qty = 1 + rnd.nextInt(100);
                    long wholesale = 100 + rnd.nextInt(9900);          // cents
                    long list = wholesale * (120 + rnd.nextInt(80)) / 100;
                    long price = list * (30 + rnd.nextInt(71)) / 100;
                    long extDiscount = (list - price) * qty;
                    long extSales = price * qty;
                    long extWholesale = wholesale * qty;
                    long extList = list * qty;
                    long tax = extSales * rnd.nextInt(9) / 100;
                    long coupon = rnd.nextInt(10) == 0 ? extSales / 10 : 0;
                    long netPaid = extSales - coupon;
                    row(w, dateSk,
                            30000 + rnd.nextInt(50000),
                            itemSk, custSk, cdemoSk, hdemoSk, addrSk, storeSk, promoSk,
                            ticket, qty,
                            cents(wholesale), cents(list), cents(price),
                            cents(extDiscount), cents(extSales), cents(extWholesale),
                            cents(extList), cents(tax), cents(coupon),
                            cents(netPaid), cents(netPaid + tax),
                            cents(netPaid - extWholesale));
                    written++;
                    if (written % 1_000_000 == 0) {
                        log.info("store_sales: {}/{}", written, sales);
                    }
                }
            }
            log.info("store_sales.dat: {} rows ({} tickets)", written, ticket);
        }
    }

    // ---------- helpers ----------

    private String yn(Random rnd) {
        return rnd.nextInt(2) == 0 ? "Y" : "N";
    }

    private BufferedWriter open(String file) throws IOException {
        return Files.newBufferedWriter(dir.resolve(file), StandardCharsets.UTF_8);
    }

    private void row(BufferedWriter w, Object... cols) {
        try {
            StringBuilder sb = new StringBuilder(200);
            for (Object c : cols) {
                sb.append(c).append('|');
            }
            sb.append('\n');
            w.write(sb.toString());
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    private String cents(long totalCents) {
        boolean neg = totalCents < 0;
        long abs = Math.abs(totalCents);
        return (neg ? "-" : "") + (abs / 100) + "." + String.format("%02d", abs % 100);
    }
}
