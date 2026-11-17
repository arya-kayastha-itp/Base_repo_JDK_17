package org.trebol.cache;

import jakarta.servlet.FilterChain;
import jakarta.servlet.http.HttpServletResponse;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;

import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Arrays;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

import static org.assertj.core.api.Assertions.assertThat;
import static org.trebol.cache.CatalogResponseCacheFilter.CACHE_HEADER;
import static org.trebol.config.Constants.AUTHORITY_CHECKOUT;

class CatalogResponseCacheFilterTest {
    private static final String BODY = "{\"items\":[]}";
    private final AtomicLong clockNanos = new AtomicLong();
    private final AtomicInteger backendCalls = new AtomicInteger();
    private int backendStatus;
    private CatalogResponseCacheFilter filter;

    /** Stands in for the controllers: counts calls and answers with the current backendStatus. */
    private final FilterChain backend = (request, response) -> {
        backendCalls.incrementAndGet();
        HttpServletResponse http = (HttpServletResponse) response;
        http.setStatus(backendStatus);
        http.setContentType("application/json");
        http.getOutputStream().write(BODY.getBytes(StandardCharsets.UTF_8));
    };

    @BeforeEach
    void beforeEach() {
        backendStatus = HttpServletResponse.SC_OK;
        filter = new CatalogResponseCacheFilter(Duration.ofSeconds(30), 1024 * 1024, clockNanos::get);
    }

    @AfterEach
    void afterEach() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void a_repeated_read_is_answered_from_the_cache() throws Exception {
        MockHttpServletResponse first = perform("GET", "pageSize=20");
        MockHttpServletResponse second = perform("GET", "pageSize=20");

        assertThat(backendCalls.get()).isEqualTo(1);
        assertThat(first.getHeader(CACHE_HEADER)).isEqualTo("MISS");
        assertThat(first.getContentAsString()).isEqualTo(BODY);
        assertThat(second.getHeader(CACHE_HEADER)).isEqualTo("HIT");
        assertThat(second.getStatus()).isEqualTo(HttpServletResponse.SC_OK);
        assertThat(second.getContentType()).isEqualTo("application/json");
        assertThat(second.getContentAsString()).isEqualTo(BODY);
    }

    @Test
    void each_query_string_is_cached_separately() throws Exception {
        perform("GET", "pageIndex=0");
        perform("GET", "pageIndex=1");
        perform("GET", null);
        perform("GET", "pageIndex=0");
        perform("GET", null);

        assertThat(backendCalls.get()).isEqualTo(3);
    }

    @Test
    void entries_expire_after_the_time_to_live() throws Exception {
        perform("GET", "pageSize=20");
        clockNanos.addAndGet(Duration.ofSeconds(31).toNanos());
        MockHttpServletResponse later = perform("GET", "pageSize=20");

        assertThat(backendCalls.get()).isEqualTo(2);
        assertThat(later.getHeader(CACHE_HEADER)).isEqualTo("MISS");
    }

    @Test
    void staff_who_can_change_the_catalog_always_get_live_data() throws Exception {
        signInWith("products:update");
        perform("GET", "pageSize=20");
        MockHttpServletResponse second = perform("GET", "pageSize=20");

        assertThat(backendCalls.get()).isEqualTo(2);
        assertThat(second.getHeader(CACHE_HEADER)).isNull();
    }

    @Test
    void customers_share_the_cached_copy() throws Exception {
        signInWith(AUTHORITY_CHECKOUT);
        perform("GET", "pageSize=20");
        perform("GET", "pageSize=20");

        assertThat(backendCalls.get()).isEqualTo(1);
    }

    @Test
    void unsuccessful_reads_are_not_cached() throws Exception {
        backendStatus = HttpServletResponse.SC_NOT_FOUND;
        perform("GET", "barcode=none");
        perform("GET", "barcode=none");

        assertThat(backendCalls.get()).isEqualTo(2);
    }

    @Test
    void a_successful_write_clears_the_cache() throws Exception {
        perform("GET", "pageSize=20");
        signInWith("products:update");
        backendStatus = HttpServletResponse.SC_CREATED;
        perform("POST", null);
        SecurityContextHolder.clearContext();
        backendStatus = HttpServletResponse.SC_OK;
        MockHttpServletResponse after = perform("GET", "pageSize=20");

        assertThat(backendCalls.get()).isEqualTo(3);
        assertThat(after.getHeader(CACHE_HEADER)).isEqualTo("MISS");
    }

    @Test
    void a_rejected_write_keeps_the_cache() throws Exception {
        perform("GET", "pageSize=20");
        backendStatus = HttpServletResponse.SC_FORBIDDEN;
        perform("DELETE", "id=1");
        backendStatus = HttpServletResponse.SC_OK;
        MockHttpServletResponse after = perform("GET", "pageSize=20");

        assertThat(backendCalls.get()).isEqualTo(2);
        assertThat(after.getHeader(CACHE_HEADER)).isEqualTo("HIT");
    }

    @Test
    void other_methods_neither_use_nor_clear_the_cache() throws Exception {
        perform("GET", "pageSize=20");
        perform("OPTIONS", "pageSize=20");
        perform("HEAD", "pageSize=20");
        MockHttpServletResponse after = perform("GET", "pageSize=20");

        assertThat(backendCalls.get()).isEqualTo(3);
        assertThat(after.getHeader(CACHE_HEADER)).isEqualTo("HIT");
    }

    private MockHttpServletResponse perform(String method, String queryString) throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest(method, "/data/products");
        request.setQueryString(queryString);
        MockHttpServletResponse response = new MockHttpServletResponse();
        filter.doFilter(request, response, backend);
        return response;
    }

    private static void signInWith(String... authorities) {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(
            "someone", null, Arrays.stream(authorities).map(SimpleGrantedAuthority::new).toList()));
    }
}
