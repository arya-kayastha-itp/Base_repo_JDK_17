package org.trebol.cache;

import com.github.benmanes.caffeine.cache.Cache;
import com.github.benmanes.caffeine.cache.Caffeine;
import com.github.benmanes.caffeine.cache.Ticker;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.http.HttpMethod;
import org.springframework.lang.NonNull;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.filter.OncePerRequestFilter;
import org.springframework.web.util.ContentCachingResponseWrapper;

import java.io.IOException;
import java.time.Duration;
import java.util.regex.Pattern;

/**
 * Short-lived cache, kept in each replica, for the public catalog reads (products, categories, product lists and
 * their contents). These responses are the same for every caller, so one stored copy can answer many requests
 * without any database work.
 * <ul>
 *   <li>Only successful (200) GET responses are stored, for a short time to live (30 s by default).</li>
 *   <li>Callers who may change the catalog (a catalog write authority, such as {@code products:update}) always
 *   get live data, so staff see their own changes at once. Their successful writes also clear this replica's
 *   cache; other replicas catch up within the time to live.</li>
 * </ul>
 * Registered after Spring Security's filter chain (see {@link CatalogCacheConfig}): the caller is known and the
 * CORS headers are already set when this filter runs.
 */
public class CatalogResponseCacheFilter
    extends OncePerRequestFilter {
    public static final String CACHE_HEADER = "X-Cache";
    private static final Pattern CATALOG_WRITE_AUTHORITY =
        Pattern.compile("(products|product_categories|product_lists):(create|update|delete|contents)");
    private final Cache<String, CachedResponse> cache;

    public CatalogResponseCacheFilter(Duration timeToLive, long maxSizeBytes) {
        this(timeToLive, maxSizeBytes, Ticker.systemTicker());
    }

    CatalogResponseCacheFilter(Duration timeToLive, long maxSizeBytes, Ticker ticker) {
        this.cache = Caffeine.newBuilder()
            .expireAfterWrite(timeToLive)
            .maximumWeight(maxSizeBytes)
            .weigher((String key, CachedResponse value) -> key.length() + value.body.length)
            .ticker(ticker)
            .build();
    }

    @Override
    protected void doFilterInternal(
        @NonNull HttpServletRequest request,
        @NonNull HttpServletResponse response,
        @NonNull FilterChain chain
    ) throws ServletException, IOException {
        String method = request.getMethod();
        if (HttpMethod.GET.matches(method) && !callerCanChangeCatalog()) {
            serveFromCache(request, response, chain);
            return;
        }
        chain.doFilter(request, response);
        if (isWrite(method) && response.getStatus() < HttpServletResponse.SC_BAD_REQUEST) {
            cache.invalidateAll();
        }
    }

    private void serveFromCache(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
        throws ServletException, IOException {
        String key = cacheKey(request);
        CachedResponse cached = cache.getIfPresent(key);
        if (cached != null) {
            response.setStatus(HttpServletResponse.SC_OK);
            if (cached.contentType != null) {
                response.setContentType(cached.contentType);
            }
            response.setContentLength(cached.body.length);
            response.setHeader(CACHE_HEADER, "HIT");
            response.getOutputStream().write(cached.body);
            return;
        }
        ContentCachingResponseWrapper wrapper = new ContentCachingResponseWrapper(response);
        wrapper.setHeader(CACHE_HEADER, "MISS");
        try {
            chain.doFilter(request, wrapper);
            if (wrapper.getStatus() == HttpServletResponse.SC_OK) {
                cache.put(key, new CachedResponse(wrapper));
            }
        } finally {
            wrapper.copyBodyToResponse();
        }
    }

    private static String cacheKey(HttpServletRequest request) {
        String query = request.getQueryString();
        return (query == null) ? request.getRequestURI() : request.getRequestURI() + "?" + query;
    }

    private static boolean callerCanChangeCatalog() {
        Authentication authentication = SecurityContextHolder.getContext().getAuthentication();
        if (authentication == null) {
            return false;
        }
        for (GrantedAuthority authority : authentication.getAuthorities()) {
            String name = authority.getAuthority();
            if (name != null && CATALOG_WRITE_AUTHORITY.matcher(name).matches()) {
                return true;
            }
        }
        return false;
    }

    private static boolean isWrite(String method) {
        return HttpMethod.POST.matches(method) || HttpMethod.PUT.matches(method)
            || HttpMethod.PATCH.matches(method) || HttpMethod.DELETE.matches(method);
    }

    private static final class CachedResponse {
        private final String contentType;
        private final byte[] body;

        private CachedResponse(ContentCachingResponseWrapper response) {
            this.contentType = response.getContentType();
            this.body = response.getContentAsByteArray();
        }
    }
}
