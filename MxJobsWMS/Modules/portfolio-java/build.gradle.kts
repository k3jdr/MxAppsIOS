// Gradle build, equivalent to pom.xml; use either.
plugins {
    java
    application
}

group = "com.k3jdr.mxjobs"
version = "1.0.0"

// Compile for Java 17 with whichever JDK runs Gradle (same as Maven's <maven.compiler.release>17).
tasks.withType<JavaCompile>().configureEach {
    options.release.set(17)
    options.encoding = "UTF-8"
}

repositories { mavenCentral() }

dependencies {
    testImplementation(platform("org.junit:junit-bom:5.11.3"))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

application { mainClass.set("com.k3jdr.mxjobs.portfolio.Server") }

tasks.test { useJUnitPlatform() }

tasks.jar {
    archiveFileName.set("portfolio-java.jar")
    manifest { attributes["Main-Class"] = "com.k3jdr.mxjobs.portfolio.Server" }
}
