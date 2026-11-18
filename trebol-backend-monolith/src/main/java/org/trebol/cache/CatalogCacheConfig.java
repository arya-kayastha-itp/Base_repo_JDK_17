package org.trebol.cache;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.time.Duration;

/**
 * Registers {@link CatalogResponseCacheFilter} for the public catalog read paths only.
 * Settings: {@code trebol.cache.catalog.*} in application.properties (can be switched off with
 * {@code TREBOL_CACHE_CATALOG_ENABLED=false}).
 */
@Configuration
public class CatalogCacheConfig {
    private static final String[] CATALOG_PATHS = {
        "/data/products", "/data/product_categories", "/data/product_lists", "/data/product_list_contents"
    };

    @Bean
    @ConditionalOnProperty(prefix = "trebol.cache.catalog", name = "enabled", havingValue = "true", matchIfMissing = true)
    public FilterRegistrationBean<CatalogResponseCacheFilter> catalogResponseCacheFilter(
        @Value("${trebol.cache.catalog.time-to-live-seconds:30}") long timeToLiveSeconds,
        @Value("${trebol.cache.catalog.max-size-megabytes:32}") long maxSizeMegabytes
    ) {
        CatalogResponseCacheFilter filter = new CatalogResponseCacheFilter(
            Duration.ofSeconds(timeToLiveSeconds), maxSizeMegabytes * 1024 * 1024);
        FilterRegistrationBean<CatalogResponseCacheFilter> registration = new FilterRegistrationBean<>(filter);
        registration.addUrlPatterns(CATALOG_PATHS);
        // After Spring Security's filter chain (order -100), so the caller is known and CORS headers are set
        registration.setOrder(0);
        return registration;
    }
}
